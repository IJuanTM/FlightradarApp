import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Fetched on-demand for the selected aircraft's historical track only, never polled continuously.
// Route lookup lives in RouteClient instead (free, no-auth, callsign-keyed - see its own header comment).
class OpenSkyClient {
    private const TOKEN_URL =
        "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token";
    // "/tracks/all", not "/tracks" - OpenSky's own prose REST doc is stale on this.
    private const TRACKS_URL = "https://opensky-network.org/api/tracks/all";
    private const TOKEN_SAFETY_MARGIN_MS = 60000;

    typedef TrackCallback as
        (Method
            (
                points as Array<[Float, Float, Number, Boolean]>,
                ok as Boolean
            ) as Void
        );

    private var _clientId as String?;
    private var _clientSecret as String?;
    private var _accessToken as String?;
    private var _tokenExpiresAtMs as Number?;
    // Hex/callback the in-flight request belongs to, kept separate from a newer call queued behind it so a response is never delivered under the wrong hex/callback.
    private var _activeTrackHex as String?;
    private var _activeTrackCallback as TrackCallback?;
    private var _queuedTrackHex as String?;
    private var _queuedTrackCallback as TrackCallback?;
    private var _retriedTrackAuth as Boolean = false;

    public function initialize() {}

    // A second call while one is already active queues instead of starting a second physical request; see _resolveTrack for how it's promoted.
    public function fetchTrack(
        hex as String,
        callback as TrackCallback
    ) as Void {
        if (_activeTrackCallback != null) {
            _queuedTrackHex = hex;
            _queuedTrackCallback = callback;
            return;
        }
        _activeTrackHex = hex;
        _activeTrackCallback = callback;
        _retriedTrackAuth = false;
        _dispatchTrackFetch();
    }

    private function _dispatchTrackFetch() as Void {
        var token = _accessToken;
        var expiresAt = _tokenExpiresAtMs;
        if (
            token != null &&
            expiresAt != null &&
            System.getTimer() < expiresAt
        ) {
            _fetchTrackWithToken(token);
            return;
        }
        _requestToken();
    }

    private function _requestToken() as Void {
        if (!_ensureCredentialsLoaded()) {
            _failPendingTrack();
            return;
        }

        var params = {
            "grant_type" => "client_credentials",
            "client_id" => _clientId,
            "client_secret" => _clientSecret,
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type"
                =>
                Communications.REQUEST_CONTENT_TYPE_URL_ENCODED,
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
        };
        Communications.makeWebRequest(
            TOKEN_URL,
            params,
            options,
            method(:_onTokenReceive)
        );
    }

    private function _ensureCredentialsLoaded() as Boolean {
        if (_clientId != null && _clientSecret != null) {
            return true;
        }

        var creds =
            WatchUi.loadResource(Rez.JsonData.Credentials) as Dictionary;
        var openSky = creds["OpenSky"] as Dictionary;
        var id = openSky["clientId"];
        var secret = openSky["clientSecret"];
        if (!(id instanceof String) or !(secret instanceof String)) {
            return false;
        }

        _clientId = id;
        _clientSecret = secret;
        return true;
    }

    public function _onTokenReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode != 200 or !(data instanceof Dictionary)) {
            _failPendingTrack();
            return;
        }

        var dict = data as Dictionary;
        var token = dict["access_token"];
        var expiresIn = dict["expires_in"];
        if (!(token instanceof String) or expiresIn == null) {
            _failPendingTrack();
            return;
        }

        _accessToken = token;
        _tokenExpiresAtMs =
            System.getTimer() +
            expiresIn.toNumber() * 1000 -
            TOKEN_SAFETY_MARGIN_MS;

        if (_activeTrackHex != null) {
            _fetchTrackWithToken(token);
        }
    }

    public function _fetchTrackWithToken(token as String) as Void {
        var hex = _activeTrackHex;
        if (hex == null) {
            return;
        }
        var url = TRACKS_URL + "?icao24=" + hex + "&time=0";
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + token },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
        };
        Communications.makeWebRequest(
            url,
            null,
            options,
            method(:_onTrackReceive)
        );
    }

    public function _onTrackReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode == 401 && !_retriedTrackAuth) {
            _retriedTrackAuth = true;
            _accessToken = null;
            _tokenExpiresAtMs = null;
            _requestToken();
            return;
        }

        if (responseCode != 200 or !(data instanceof Dictionary)) {
            _failPendingTrack();
            return;
        }

        var pathRaw = (data as Dictionary)["path"];
        var points = [] as Array<[Float, Float, Number, Boolean]>;
        if (pathRaw instanceof Array) {
            for (var i = 0; i < pathRaw.size(); i++) {
                var wp = pathRaw[i];
                if (wp instanceof Array && wp.size() >= 6) {
                    var lat = wp[1];
                    var lon = wp[2];
                    var alt = wp[3];
                    var onGround = wp[5];
                    if (lat != null && lon != null) {
                        points.add([
                            lat.toFloat(),
                            lon.toFloat(),
                            // OpenSky reports meters, airplanes.live (and this whole app) works in feet.
                            alt != null
                                ? (alt.toFloat() * 3.28084).toNumber()
                                : 0,
                            onGround instanceof Boolean && onGround,
                        ]);
                    }
                }
            }
        }

        _resolveTrack(points, true);
    }

    private function _failPendingTrack() as Void {
        _resolveTrack([] as Array<[Float, Float, Number, Boolean]>, false);
    }

    // Delivers to the active request's own callback before promoting any queued request, so a response is never attributed to the wrong hex/callback.
    private function _resolveTrack(
        points as Array<[Float, Float, Number, Boolean]>,
        ok as Boolean
    ) as Void {
        var cb = _activeTrackCallback;
        _activeTrackHex = null;
        _activeTrackCallback = null;
        if (cb != null) {
            cb.invoke(points, ok);
        }
        var queuedHex = _queuedTrackHex;
        var queuedCallback = _queuedTrackCallback;
        if (queuedHex != null && queuedCallback != null) {
            _queuedTrackHex = null;
            _queuedTrackCallback = null;
            _activeTrackHex = queuedHex;
            _activeTrackCallback = queuedCallback;
            _retriedTrackAuth = false;
            _dispatchTrackFetch();
        }
    }
}
