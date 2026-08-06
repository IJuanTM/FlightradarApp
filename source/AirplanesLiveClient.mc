import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// A class (not a module) because Communications.makeWebRequest's callback needs a bound method(:symbol).
class AirplanesLiveClient {
    private const BASE_URL = "https://api.airplanes.live/v2/point";

    // tooMuchData distinguishes the known response-size-ceiling failure (-402/-403) from a generic failure.
    typedef FetchCallback as
        (Method
            (
                aircraft as Array<Aircraft>,
                ok as Boolean,
                tooMuchData as Boolean
            ) as Void
        );

    // airplanes.live documents a 1 req/sec limit - a bit of margin above that.
    private const MIN_REQUEST_INTERVAL_MS = 1050;

    // SDK docs: Timer's minimum interval defaults to 50ms and depends on the host system.
    private const MIN_TIMER_INTERVAL_MS = 50;

    // Lat/lon/radius/callback the in-flight request belongs to, kept separate from a newer call queued behind it so a response is never attributed to the wrong focus point.
    private var _activeLat as Float?;
    private var _activeLon as Float?;
    private var _activeRadiusKm as Float?;
    private var _activeCallback as FetchCallback?;
    private var _queuedLat as Float?;
    private var _queuedLon as Float?;
    private var _queuedRadiusKm as Float?;
    private var _queuedCallback as FetchCallback?;
    private var _lastRequestStartMs as Number?;
    // Held here, not a local - an unreferenced Timer can be garbage-collected before it fires.
    private var _throttleTimer as Timer.Timer?;
    // True from _performFetch until _onReceive fires - fetch() defers instead of issuing a second real request while this is set.
    private var _awaitingReceive as Boolean = false;

    public function initialize() {}

    public function fetch(
        lat as Float,
        lon as Float,
        radiusKm as Float,
        callback as FetchCallback
    ) as Void {
        if (_awaitingReceive) {
            _queuedLat = lat;
            _queuedLon = lon;
            _queuedRadiusKm = radiusKm;
            _queuedCallback = callback;
            return;
        }
        _activeLat = lat;
        _activeLon = lon;
        _activeRadiusKm = radiusKm;
        _activeCallback = callback;
        _dispatchOrThrottle();
    }

    private function _dispatchOrThrottle() as Void {
        var lastStart = _lastRequestStartMs;
        var elapsed =
            lastStart != null
                ? System.getTimer() - lastStart
                : MIN_REQUEST_INTERVAL_MS;
        if (elapsed >= MIN_REQUEST_INTERVAL_MS) {
            _performFetch();
            return;
        }

        var delay = MIN_REQUEST_INTERVAL_MS - elapsed;
        _throttleTimer = new Timer.Timer();
        (_throttleTimer as Timer.Timer).start(
            method(:_onThrottleElapsed),
            delay < MIN_TIMER_INTERVAL_MS ? MIN_TIMER_INTERVAL_MS : delay,
            false
        );
    }

    public function _onThrottleElapsed() as Void {
        _performFetch();
    }

    private function _performFetch() as Void {
        _lastRequestStartMs = System.getTimer();
        _awaitingReceive = true;

        var radiusNm = (_activeRadiusKm as Float) * 0.539957;
        if (radiusNm < 1.0) {
            radiusNm = 1.0;
        }

        var url =
            BASE_URL +
            "/" +
            (_activeLat as Float).toString() +
            "/" +
            (_activeLon as Float).toString() +
            "/" +
            radiusNm.format("%.1f");
        // No :responseType - this endpoint's Content-Type varies (JSON normally, text/plain on a 429),
        // and a fixed responseType gets rejected outright on real devices when it doesn't match.
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
        };

        Communications.makeWebRequest(url, null, options, method(:_onReceive));
    }

    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        _awaitingReceive = false;

        if (responseCode != 200 or !(data instanceof Dictionary)) {
            _resolveFetch([], false, _isSizeCeilingError(responseCode));
            return;
        }

        var acRaw = (data as Dictionary).get("ac");
        if (!(acRaw instanceof Array)) {
            _resolveFetch([], false, false);
            return;
        }

        var arr = acRaw as Array;
        var result = [] as Array<Aircraft>;
        for (var i = 0; i < arr.size(); i++) {
            result.add(new Aircraft(arr[i] as Dictionary));
        }
        _resolveFetch(result, true, false);
    }

    // Delivers to the active request's own callback before promoting any queued request, so a response is never attributed to the wrong focus point.
    private function _resolveFetch(
        aircraft as Array<Aircraft>,
        ok as Boolean,
        tooMuchData as Boolean
    ) as Void {
        var cb = _activeCallback;
        _activeCallback = null;
        if (cb != null) {
            cb.invoke(aircraft, ok, tooMuchData);
        }

        var queuedLat = _queuedLat;
        var queuedLon = _queuedLon;
        var queuedRadiusKm = _queuedRadiusKm;
        var queuedCallback = _queuedCallback;
        if (
            queuedLat != null &&
            queuedLon != null &&
            queuedRadiusKm != null &&
            queuedCallback != null
        ) {
            _queuedLat = null;
            _queuedLon = null;
            _queuedRadiusKm = null;
            _queuedCallback = null;
            _activeLat = queuedLat;
            _activeLon = queuedLon;
            _activeRadiusKm = queuedRadiusKm;
            _activeCallback = queuedCallback;
            _dispatchOrThrottle();
        }
    }

    // -402/-403 are Communications' own response-size/memory-ceiling codes - distinct from a real connectivity failure.
    private function _isSizeCeilingError(responseCode as Number) as Boolean {
        return responseCode == -402 or responseCode == -403;
    }
}
