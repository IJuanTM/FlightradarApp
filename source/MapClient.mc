import Toybox.Communications;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

class MapClient {
    private const URL_PREFIX = "https://api.maptiler.com/maps/";
    // Must equal the real fetched bitmap size - draw-scale math divides by it.
    public const TILE_SIZE_STD as Number = 256;
    // 256 reference tile at @2x - a distinct render, not interchangeable with MapTiler's own 512 tile.
    public const TILE_SIZE_HI as Number = 512;
    // Generous margin above the slowest cold fetch actually measured (~1s) - a hung tile would otherwise permanently block every other tile and the aircraft poll behind it.
    private const TILE_TIMEOUT_MS = 3000;
    // SDK docs: Timer's minimum interval defaults to 50ms - same floor AdsbFiClient's own throttle uses.
    private const MIN_WAKE_DELAY_MS = 50;

    private var _apiKey as String?;
    private var _currentStartMs as Number?;
    // One-shot, not a local - see AdsbFiClient._throttleTimer for why an unstored Timer is unsafe.
    private var _wakeTimer as Timer.Timer?;

    typedef MapBitmap as Graphics.BitmapReference or WatchUi.BitmapResource;
    typedef TileCallback as
        (Method
            (
                z as Number,
                x as Number,
                y as Number,
                tileSize as Number,
                bitmap as MapBitmap?
            ) as Void
        );
    private var _callback as TileCallback?;

    private var _current as [Number, Number, Number, Number]?;
    private var _queue as Array<[Number, Number, Number, Number]> = [];
    // True from _dispatch until _onReceive fires, and stays true across an abandon - makeImageRequest has no :context param, so a late real response can't be correlated and must be assumed still able to land.
    private var _awaitingReceive as Boolean = false;
    // Shared request channel to the paired phone; keyed by owner (not a count) so each owner's pauseFor()/resumeFor() pair is independently idempotent.
    private var _pausedBy as Dictionary<Symbol, Boolean> = {};

    public function initialize(callback as TileCallback) {
        _callback = callback;
    }

    public function pauseFor(owner as Symbol) as Void {
        _pausedBy[owner] = true;
    }

    // Never dispatches directly here (still the off-limits nested-Communications shape) - a one-shot Timer wakes it sooner instead.
    public function resumeFor(owner as Symbol) as Void {
        if (_pausedBy.hasKey(owner)) {
            _pausedBy.remove(owner);
        }
        if (
            _pausedBy.size() == 0 and
            _queue.size() > 0 and
            _wakeTimer == null
        ) {
            _wakeTimer = new Timer.Timer();
            (_wakeTimer as Timer.Timer).start(
                method(:_onWake),
                MIN_WAKE_DELAY_MS,
                false
            );
        }
    }

    public function _onWake() as Void {
        _wakeTimer = null;
        _dispatchNextIfIdle();
    }

    // Call once per timer tick: reports a hung tile as failed (not cancelled - cancelAllRequests() crashed on-device) and dispatches the next queued tile if idle.
    public function tick() as Void {
        var startedAt = _currentStartMs;
        if (
            _current != null and
            startedAt != null and
            System.getTimer() - startedAt > TILE_TIMEOUT_MS
        ) {
            _abandonCurrent();
        }
        _dispatchNextIfIdle();
    }

    // True while a tile is in flight or its abandoned response could still land - other callers on the shared channel must wait rather than start a competing real request.
    public function isBusy() as Boolean {
        return _current != null or _awaitingReceive;
    }

    public function requestTile(
        z as Number,
        x as Number,
        y as Number,
        tileSize as Number
    ) as Void {
        var current = _current;
        if (
            current != null and
            current[0] == z and
            current[1] == x and
            current[2] == y and
            current[3] == tileSize
        ) {
            return;
        }
        for (var i = 0; i < _queue.size(); i++) {
            var q = _queue[i];
            if (q[0] == z and q[1] == x and q[2] == y and q[3] == tileSize) {
                return;
            }
        }
        if (current != null or _awaitingReceive or _pausedBy.size() > 0) {
            _queue.add([z, x, y, tileSize]);
            return;
        }
        if (!_ensureApiKeyLoaded()) {
            return;
        }
        _dispatch(z, x, y, tileSize);
    }

    // Also abandons an in-flight tile that's no longer needed - otherwise isBusy() stays true up to TILE_TIMEOUT_MS after a zoom change for a tile nothing needs.
    public function pruneQueue(
        neededKeys as Dictionary<String, Boolean>
    ) as Void {
        var current = _current;
        var currentStillNeeded =
            current == null or neededKeys.hasKey(_keyFor(current));
        if (_queue.size() == 0 and currentStillNeeded) {
            return;
        }
        var kept = [] as Array<[Number, Number, Number, Number]>;
        for (var i = 0; i < _queue.size(); i++) {
            var q = _queue[i];
            if (neededKeys.hasKey(_keyFor(q))) {
                kept.add(q);
            }
        }
        _queue = kept;
        if (!currentStillNeeded) {
            _abandonCurrent();
        }
    }

    // Shared with RadarView so both sides agree on one tile-identity key format.
    public function tileKeyFor(
        z as Number,
        x as Number,
        y as Number,
        tileSize as Number
    ) as String {
        return (
            z.toString() +
            "_" +
            x.toString() +
            "_" +
            y.toString() +
            "_" +
            tileSize.toString()
        );
    }

    private function _keyFor(t as [Number, Number, Number, Number]) as String {
        return tileKeyFor(
            t[0] as Number,
            t[1] as Number,
            t[2] as Number,
            t[3] as Number
        );
    }

    // Reports a failure for the current tile and frees isBusy()/dedupe state, but deliberately leaves _awaitingReceive set - see that field's own comment for why.
    private function _abandonCurrent() as Void {
        var req = _current;
        _current = null;
        _currentStartMs = null;
        var cb = _callback;
        if (cb != null and req != null) {
            cb.invoke(
                req[0] as Number,
                req[1] as Number,
                req[2] as Number,
                req[3] as Number,
                null
            );
        }
    }

    private function _dispatch(
        z as Number,
        x as Number,
        y as Number,
        tileSize as Number
    ) as Void {
        _current = [z, x, y, tileSize];
        _currentStartMs = System.getTimer();
        _awaitingReceive = true;
        var opt = Settings.mapStyleOption(Settings.mapStyle);
        var suffix = opt != null ? opt.urlSuffix : "-v4";
        var url =
            URL_PREFIX +
            Settings.mapStyle +
            suffix +
            (Settings.mapDarkMode ? "-dark" : "") +
            "/" +
            TILE_SIZE_STD.toString() +
            "/" +
            z.toString() +
            "/" +
            x.toString() +
            "/" +
            y.toString() +
            (tileSize == TILE_SIZE_HI ? "@2x" : "") +
            ".png";
        var params = {
            "key" => _apiKey,
        };
        Communications.makeImageRequest(url, params, {}, method(:_onReceive));
    }

    public function _onReceive(
        responseCode as Number,
        data as MapBitmap?
    ) as Void {
        _awaitingReceive = false;
        // If _current is already null, this request was abandoned (timeout/prune) and its failure already reported - discard the late response rather than misattribute it.
        var req = _current;
        _current = null;
        var cb = _callback;
        if (cb != null and req != null) {
            cb.invoke(
                req[0] as Number,
                req[1] as Number,
                req[2] as Number,
                req[3] as Number,
                responseCode == 200 ? data : null
            );
        }
        _dispatchNextIfIdle();
    }

    private function _dispatchNextIfIdle() as Void {
        if (
            _current != null or
            _awaitingReceive or
            _pausedBy.size() > 0 or
            _queue.size() == 0
        ) {
            return;
        }
        // A tile can land in the queue via requestTile's enqueue-while-busy branch before the key
        // was ever loaded (e.g. paused at startup, before any dispatch has run) - check here too.
        if (!_ensureApiKeyLoaded()) {
            return;
        }
        var next = _queue[0];
        _queue = _queue.slice(1, null);
        _dispatch(
            next[0] as Number,
            next[1] as Number,
            next[2] as Number,
            next[3] as Number
        );
    }

    private function _ensureApiKeyLoaded() as Boolean {
        if (_apiKey != null) {
            return true;
        }
        var values = CredentialsUtil.loadStrings("MapTiler", ["apiKey"]);
        if (values == null) {
            return false;
        }
        _apiKey = values[0];
        return true;
    }
}
