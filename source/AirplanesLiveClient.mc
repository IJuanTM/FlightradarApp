import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// A class (not a module) because Communications.makeWebRequest's callback needs a bound method(:symbol).
class AirplanesLiveClient {
    private const BASE_URL = "https://api.airplanes.live/v2/point";

    // tooMuchData distinguishes the known response-size-ceiling failure (-402/-403) from a generic failure.
    // code is the raw Communications response code, for on-watch diagnosis.
    typedef FetchCallback as
        (Method
            (
                aircraft as Array<Aircraft>,
                ok as Boolean,
                tooMuchData as Boolean,
                code as Number
            ) as Void
        );

    // airplanes.live documents a 1 req/sec limit - a bit of margin above that.
    private const MIN_REQUEST_INTERVAL_MS = 1100;

    // SDK docs: Timer's minimum interval defaults to 50ms and depends on the host system.
    private const MIN_TIMER_INTERVAL_MS = 50;

    private var _pendingLat as Float?;
    private var _pendingLon as Float?;
    private var _pendingRadiusKm as Float?;
    private var _pendingCallback as FetchCallback?;
    private var _lastRequestStartMs as Number?;
    // Held here, not a local - an unreferenced Timer can be garbage-collected before it fires.
    private var _throttleTimer as Timer.Timer?;

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
        var cb = _pendingCallback;
        if (cb == null) {
            return;
        }

        if (responseCode != 200 or !(data instanceof Dictionary)) {
            cb.invoke(
                [],
                false,
                _isSizeCeilingError(responseCode),
                responseCode
            );
            return;
        }

        var acRaw = (data as Dictionary).get("ac");
        if (!(acRaw instanceof Array)) {
            cb.invoke([], false, false, responseCode);
            return;
        }

        var arr = acRaw as Array;
        var result = [] as Array<Aircraft>;
        for (var i = 0; i < arr.size(); i++) {
            result.add(new Aircraft(arr[i] as Dictionary));
        }
        cb.invoke(result, true, false, responseCode);
    }

    // -402/-403 are Communications' own response-size/memory-ceiling codes - distinct from a real connectivity failure.
    private function _isSizeCeilingError(responseCode as Number) as Boolean {
        return responseCode == -402 or responseCode == -403;
    }
}
