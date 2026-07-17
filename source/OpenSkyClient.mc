import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Fetched on-demand for the selected aircraft only, never polled continuously.
class OpenSkyClient {
    private const TOKEN_URL =
        "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token";
    // "/tracks/all", not "/tracks" - OpenSky's own prose REST doc is stale on this.
    private const TRACKS_URL = "https://opensky-network.org/api/tracks/all";
    private const TOKEN_SAFETY_MARGIN_MS = 60000;

    typedef TrackCallback as
        (Method(points as Array<[Float, Float]>, ok as Boolean) as Void);

    private var _clientId as String?;
    private var _clientSecret as String?;
    private var _accessToken as String?;
    private var _tokenExpiresAtMs as Number?;
    private var _pendingHex as String?;
    private var _pendingCallback as TrackCallback?;
    private var _retriedAuth as Boolean = false;

    public function initialize() {}

    public function fetchTrack(
        hex as String,
        callback as TrackCallback
    ) as Void {
        _pendingHex = hex;
        _pendingCallback = callback;
        _retriedAuth = false;

        var token = _accessToken;
        var expiresAt = _tokenExpiresAtMs;
        if (
            token != null &&
            expiresAt != null &&
            System.getTimer() < expiresAt
        ) {
            _fetchTrackWithToken(hex, token);
            return;
        }

        _requestToken();
    }

    private function _requestToken() as Void {
        if (!_ensureCredentialsLoaded()) {
            _failPending();
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
            WatchUi.loadResource(Rez.JsonData.OpenSkyCredentials) as Dictionary;
        var id = creds["clientId"];
        var secret = creds["clientSecret"];
        if (!(id instanceof String) or !(secret instanceof String)) {
            return false;
        }

        _clientId = id;
        _clientSecret = secret;
        return true;
    }

    // Public so method(:_onTokenReceive) isn't optimized away as an unreferenced private symbol.
    public function _onTokenReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode != 200 or !(data instanceof Dictionary)) {
            _failPending();
            return;
        }

        var dict = data as Dictionary;
        var token = dict["access_token"];
        var expiresIn = dict["expires_in"];
        if (!(token instanceof String) or expiresIn == null) {
            _failPending();
            return;
        }

        _accessToken = token;
        _tokenExpiresAtMs =
            System.getTimer() +
            expiresIn.toNumber() * 1000 -
            TOKEN_SAFETY_MARGIN_MS;

        var hex = _pendingHex;
        if (hex != null) {
            _fetchTrackWithToken(hex, token);
        }
    }

    private function _fetchTrackWithToken(
        hex as String,
        token as String
    ) as Void {
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

    // Public so method(:_onTrackReceive) isn't optimized away as an unreferenced private symbol.
    public function _onTrackReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode == 401 && !_retriedAuth) {
            _retriedAuth = true;
            _accessToken = null;
            _tokenExpiresAtMs = null;
            _requestToken();
            return;
        }

        if (responseCode != 200 or !(data instanceof Dictionary)) {
            _failPending();
            return;
        }

        var pathRaw = (data as Dictionary)["path"];
        var points = [] as Array<[Float, Float]>;
        if (pathRaw instanceof Array) {
            for (var i = 0; i < pathRaw.size(); i++) {
                var wp = pathRaw[i];
                if (wp instanceof Array && wp.size() >= 3) {
                    var lat = wp[1];
                    var lon = wp[2];
                    if (lat != null && lon != null) {
                        points.add([lat.toFloat(), lon.toFloat()]);
                    }
                }
            }
        }

        var cb = _pendingCallback;
        _pendingCallback = null;
        _pendingHex = null;
        if (cb != null) {
            cb.invoke(points, true);
        }
    }

    private function _failPending() as Void {
        var cb = _pendingCallback;
        _pendingCallback = null;
        _pendingHex = null;
        if (cb != null) {
            cb.invoke([], false);
        }
    }
}
