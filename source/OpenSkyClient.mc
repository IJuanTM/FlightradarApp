import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// Fetched on-demand for the selected aircraft only, never polled continuously.
class OpenSkyClient {
    private const TOKEN_URL =
        "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token";
    // "/tracks/all", not "/tracks" - OpenSky's own prose REST doc is stale on this.
    private const TRACKS_URL = "https://opensky-network.org/api/tracks/all";
    private const FLIGHTS_URL =
        "https://opensky-network.org/api/flights/aircraft";
    private const TOKEN_SAFETY_MARGIN_MS = 60000;
    // flights/aircraft needs a begin/end window - wide enough to reliably catch a flight that started hours ago.
    private const ROUTE_LOOKBACK_SEC = 24 * 3600;
    // Beyond this, the last completed flight is treated as too stale to plausibly still be relevant.
    private const MAX_ROUTE_AGE_SEC = 12 * 3600;

    typedef TrackCallback as
        (Method
            (
                points as Array<[Float, Float, Number, Boolean]>,
                ok as Boolean
            ) as Void
        );
    typedef RouteCallback as
        (Method(dep as String?, arr as String?, ok as Boolean) as Void);
    typedef TokenDispatch as (Method(token as String) as Void);

    private var _clientId as String?;
    private var _clientSecret as String?;
    private var _accessToken as String?;
    private var _tokenExpiresAtMs as Number?;
    // Track and route requests are independent - each gets its own pending slot so one can't clobber the other.
    private var _pendingTrackHex as String?;
    private var _pendingTrackCallback as TrackCallback?;
    private var _retriedTrackAuth as Boolean = false;
    private var _pendingRouteHex as String?;
    private var _pendingRouteCallback as RouteCallback?;
    private var _retriedRouteAuth as Boolean = false;

    public function initialize() {}

    public function fetchTrack(
        hex as String,
        callback as TrackCallback
    ) as Void {
        _pendingTrackHex = hex;
        _pendingTrackCallback = callback;
        _retriedTrackAuth = false;
        _withToken(method(:_fetchTrackWithToken));
    }

    public function fetchRoute(
        hex as String,
        callback as RouteCallback
    ) as Void {
        _pendingRouteHex = hex;
        _pendingRouteCallback = callback;
        _retriedRouteAuth = false;
        _withToken(method(:_fetchRouteWithToken));
    }

    // Shared by fetchTrack/fetchRoute, so token acquisition isn't duplicated.
    private function _withToken(dispatch as TokenDispatch) as Void {
        var token = _accessToken;
        var expiresAt = _tokenExpiresAtMs;
        if (
            token != null &&
            expiresAt != null &&
            System.getTimer() < expiresAt
        ) {
            dispatch.invoke(token);
            return;
        }
        _requestToken();
    }

    private function _requestToken() as Void {
        if (!_ensureCredentialsLoaded()) {
            _failPendingTrack();
            _failPendingRoute();
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

    public function _onTokenReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode != 200 or !(data instanceof Dictionary)) {
            _failPendingTrack();
            _failPendingRoute();
            return;
        }

        var dict = data as Dictionary;
        var token = dict["access_token"];
        var expiresIn = dict["expires_in"];
        if (!(token instanceof String) or expiresIn == null) {
            _failPendingTrack();
            _failPendingRoute();
            return;
        }

        _accessToken = token;
        _tokenExpiresAtMs =
            System.getTimer() +
            expiresIn.toNumber() * 1000 -
            TOKEN_SAFETY_MARGIN_MS;

        if (_pendingTrackHex != null) {
            _fetchTrackWithToken(token);
        }
        if (_pendingRouteHex != null) {
            _fetchRouteWithToken(token);
        }
    }

    public function _fetchTrackWithToken(token as String) as Void {
        var hex = _pendingTrackHex;
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

        var cb = _pendingTrackCallback;
        _pendingTrackCallback = null;
        _pendingTrackHex = null;
        if (cb != null) {
            cb.invoke(points, true);
        }
    }

    public function _fetchRouteWithToken(token as String) as Void {
        var hex = _pendingRouteHex;
        if (hex == null) {
            return;
        }
        // Already Unix-epoch seconds on real hardware, despite SDK docs claiming a Garmin epoch - confirmed live.
        var now = Time.now().value();
        var url =
            FLIGHTS_URL +
            "?icao24=" +
            hex +
            "&begin=" +
            (now - ROUTE_LOOKBACK_SEC).toString() +
            "&end=" +
            now.toString();
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + token },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
        };
        Communications.makeWebRequest(
            url,
            null,
            options,
            method(:_onRouteReceive)
        );
    }

    public function _onRouteReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode == 401 && !_retriedRouteAuth) {
            _retriedRouteAuth = true;
            _accessToken = null;
            _tokenExpiresAtMs = null;
            _requestToken();
            return;
        }

        // 404 just means "no flight found for this window" - a normal outcome, not a failure.
        if (responseCode == 404) {
            _completeRoute(null, null, true);
            return;
        }
        // This endpoint's JSON root is an array, but the callback type is fixed to Dictionary|String|Null - widen first.
        var raw = data as Object;
        if (responseCode != 200 or !(raw instanceof Array)) {
            _failPendingRoute();
            return;
        }

        var flights = raw as Array;
        if (flights.size() == 0) {
            _completeRoute(null, null, true);
            return;
        }
        // Array order isn't documented/guaranteed by the API - pick by lastSeen instead of array position.
        var best = null as Dictionary?;
        var bestLastSeen = null as Number?;
        for (var i = 0; i < flights.size(); i++) {
            var f = flights[i];
            if (!(f instanceof Dictionary)) {
                continue;
            }
            var lastSeen = (f as Dictionary)["lastSeen"];
            if (lastSeen == null) {
                continue;
            }
            var lastSeenNum = lastSeen.toNumber();
            if (
                bestLastSeen == null ||
                lastSeenNum > (bestLastSeen as Number)
            ) {
                best = f as Dictionary;
                bestLastSeen = lastSeenNum;
            }
        }
        // This endpoint only ever returns the aircraft's last *completed* flight (batch-processed overnight,
        // never the in-progress one) - if that segment is old enough, the aircraft has very plausibly flown
        // again since, so showing it as "the route" would likely be a different, wrong flight. Treat it the
        // same as no route found rather than risk a confidently-wrong dep/arr.
        if (
            best != null &&
            bestLastSeen != null &&
            Time.now().value() - (bestLastSeen as Number) > MAX_ROUTE_AGE_SEC
        ) {
            best = null;
        }
        var dep = null as String?;
        var arr = null as String?;
        if (best != null) {
            var depRaw = (best as Dictionary)["estDepartureAirport"];
            var arrRaw = (best as Dictionary)["estArrivalAirport"];
            dep = depRaw instanceof String ? depRaw : null;
            arr = arrRaw instanceof String ? arrRaw : null;
        }
        _completeRoute(dep, arr, true);
    }

    private function _completeRoute(
        dep as String?,
        arr as String?,
        ok as Boolean
    ) as Void {
        var cb = _pendingRouteCallback;
        _pendingRouteCallback = null;
        _pendingRouteHex = null;
        if (cb != null) {
            cb.invoke(dep, arr, ok);
        }
    }

    private function _failPendingTrack() as Void {
        var cb = _pendingTrackCallback;
        _pendingTrackCallback = null;
        _pendingTrackHex = null;
        if (cb != null) {
            cb.invoke([], false);
        }
    }

    private function _failPendingRoute() as Void {
        _completeRoute(null, null, false);
    }
}
