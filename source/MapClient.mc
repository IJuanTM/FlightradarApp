import Toybox.Communications;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.System;
import Toybox.WatchUi;

class MapClient {
    private const BASE_URL = "https://api.maptiler.com/maps/backdrop-v4-dark";
    // Must equal the real fetched bitmap size - draw-scale math divides by it.
    public const TILE_SIZE_STD as Number = 256;
    // 256 reference tile at @2x - a distinct render, not interchangeable with MapTiler's own 512 tile.
    public const TILE_SIZE_HI as Number = 512;
    // Generous margin above the slowest cold fetch actually measured (~1s) - a hung tile would
    // otherwise never clear, permanently blocking every other tile and the aircraft poll behind it.
    private const TILE_TIMEOUT_MS = 3000;

    private var _apiKey as String?;
    private var _currentStartMs as Number?;

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
    // The aircraft-data poll shares the same request channel to the paired phone - paused while
    // it's in flight so a tile batch can never queue behind it and delay aircraft positions.
    private var _paused as Boolean = false;

    public function initialize(callback as TileCallback) {
        _callback = callback;
    }

    public function pause() as Void {
        _paused = true;
    }

    // Only flips the flag - dispatching a new request from here would run nested inside whatever
    // Communications callback called resume(), which crashed on-device (a different client's own
    // callback chain, not this one's). tick() from a clean timer tick does the actual dispatch.
    public function resume() as Void {
        _paused = false;
    }

    // Call once per timer tick: recovers a hung tile (treated as a real failure via the same path
    // _onReceive already uses, not cancelled outright - cancelAllRequests() crashed on real
    // hardware) and dispatches the next queued tile if anything was left waiting on resume().
    public function tick() as Void {
        var startedAt = _currentStartMs;
        if (
            _current != null and
            startedAt != null and
            System.getTimer() - startedAt > TILE_TIMEOUT_MS
        ) {
            _onReceive(-1, null);
        }
        _dispatchNextIfIdle();
    }

    // True while a tile request is already in flight - it can't be cancelled, so the aircraft poll
    // needs to know to wait rather than start a new request that would queue up behind it.
    public function isBusy() as Boolean {
        return _current != null;
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
        if (current != null or _paused) {
            _queue.add([z, x, y, tileSize]);
            return;
        }
        if (!_ensureApiKeyLoaded()) {
            return;
        }
        _dispatch(z, x, y, tileSize);
    }

    // Only drops queued tiles - an in-flight request can't be cancelled, so it resolves and is
    // discarded by the caller if stale.
    public function pruneQueue(
        neededKeys as Dictionary<String, Boolean>
    ) as Void {
        var kept = [] as Array<[Number, Number, Number, Number]>;
        for (var i = 0; i < _queue.size(); i++) {
            var q = _queue[i];
            var key =
                q[0].toString() +
                "_" +
                q[1].toString() +
                "_" +
                q[2].toString() +
                "_" +
                q[3].toString();
            if (neededKeys.hasKey(key)) {
                kept.add(q);
            }
        }
        _queue = kept;
    }

    private function _dispatch(
        z as Number,
        x as Number,
        y as Number,
        tileSize as Number
    ) as Void {
        _current = [z, x, y, tileSize];
        _currentStartMs = System.getTimer();
        var url =
            BASE_URL +
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
        if (_current != null or _paused or _queue.size() == 0) {
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
        var creds =
            WatchUi.loadResource(Rez.JsonData.Credentials) as Dictionary;
        var mapTiler = creds["MapTiler"] as Dictionary;
        var key = mapTiler["apiKey"];
        if (!(key instanceof String)) {
            return false;
        }
        _apiKey = key;
        return true;
    }
}
