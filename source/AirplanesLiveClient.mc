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

    private var _pendingLat as Float?;
    private var _pendingLon as Float?;
    private var _pendingRadiusKm as Float?;
    private var _pendingCallback as FetchCallback?;
    private var _lastRequestStartMs as Number?;
    // Held here, not a local - an unreferenced Timer can be garbage-collected before it fires.
    private var _throttleTimer as Timer.Timer?;
    // True from _performFetch until _onReceive fires. RadarView may treat a fetch as timed-out and
    // start another one while this is still true (its own timeout is display/retry-only, unaware of
    // the real network state here) - fetch() then defers instead of issuing a second real request,
    // matching this project's established "never two requests in flight" invariant.
    private var _awaitingReceive as Boolean = false;
    private var _retryQueued as Boolean = false;

    public function initialize() {}

    public function fetch(
        lat as Float,
        lon as Float,
        radiusKm as Float,
        callback as FetchCallback
    ) as Void {
        _pendingLat = lat;
        _pendingLon = lon;
        _pendingRadiusKm = radiusKm;
        _pendingCallback = callback;

        if (_awaitingReceive) {
            _retryQueued = true;
            return;
        }
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

        var radiusNm = (_pendingRadiusKm as Float) * 0.539957;
        if (radiusNm < 1.0) {
            radiusNm = 1.0;
        }

        var url =
            BASE_URL +
            "/" +
            (_pendingLat as Float).toString() +
            "/" +
            (_pendingLon as Float).toString() +
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
        var cb = _pendingCallback;
        // Only clear the callback when nothing else is queued to reuse it - a queued fetch() call
        // already stored its own (identical) callback here, and dispatching it needs it intact.
        if (_retryQueued) {
            _retryQueued = false;
            _dispatchOrThrottle();
        } else {
            _pendingCallback = null;
        }
        if (cb == null) {
            return;
        }

        if (responseCode != 200 or !(data instanceof Dictionary)) {
            cb.invoke([], false, _isSizeCeilingError(responseCode));
            return;
        }

        var acRaw = (data as Dictionary).get("ac");
        if (!(acRaw instanceof Array)) {
            cb.invoke([], false, false);
            return;
        }

        var arr = acRaw as Array;
        var result = [] as Array<Aircraft>;
        for (var i = 0; i < arr.size(); i++) {
            result.add(new Aircraft(arr[i] as Dictionary));
        }
        cb.invoke(result, true, false);
    }

    // -402/-403 are Communications' own response-size/memory-ceiling codes - distinct from a real connectivity failure.
    private function _isSizeCeilingError(responseCode as Number) as Boolean {
        return responseCode == -402 or responseCode == -403;
    }
}
