import Toybox.Communications;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.WatchUi;

class MapClient {
    private const BASE_URL = "https://api.maptiler.com/maps/landscape-v4-dark";
    // Real on-wire pixel dimensions of what each tier actually fetches - this must match the
    // real bitmap size exactly, since the draw-scale math divides by it.
    public const TILE_SIZE_STD as Number = 256;
    // The same 256 reference tile requested at @2x - a real, distinct render (confirmed via
    // pixel-diff, not just upscaled 256), not the same content as MapTiler's separate 512 tile.
    public const TILE_SIZE_HI as Number = 512;

    private var _apiKey as String?;

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

    public function initialize(callback as TileCallback) {
        _callback = callback;
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
        if (current != null) {
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
        if (_queue.size() > 0) {
            var next = _queue[0];
            _queue = _queue.slice(1, null);
            _dispatch(
                next[0] as Number,
                next[1] as Number,
                next[2] as Number,
                next[3] as Number
            );
        }
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
