import Toybox.Communications;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.WatchUi;

class MapClient {
    private const BASE_URL = "https://maps.geoapify.com/v1/staticmap";

    private var _apiKey as String?;

    typedef MapBitmap as Graphics.BitmapReference or WatchUi.BitmapResource;
    // Echoed back so a response is attributable even if a newer request was queued meanwhile.
    typedef MapCallback as
        (Method
            (
                lat as Float,
                lon as Float,
                zoom as Float,
                width as Number,
                height as Number,
                bitmap as MapBitmap?
            ) as Void
        );
    private var _callback as MapCallback?;

    private var _current as [Float, Float, Float, Number, Number]?;
    private var _pending as [Float, Float, Float, Number, Number]?;

    public function initialize(callback as MapCallback) {
        _callback = callback;
    }

    public function fetchMap(
        lat as Float,
        lon as Float,
        zoom as Float,
        width as Number,
        height as Number
    ) as Void {
        if (_current != null) {
            _pending = [lat, lon, zoom, width, height];
            return;
        }
        if (!_ensureApiKeyLoaded()) {
            return;
        }
        _dispatch(lat, lon, zoom, width, height);
    }

    private function _dispatch(
        lat as Float,
        lon as Float,
        zoom as Float,
        width as Number,
        height as Number
    ) as Void {
        _current = [lat, lon, zoom, width, height];
        var params = {
            "apiKey" => _apiKey,
            "style" => "dark-matter",
            "center" => "lonlat:" + lon.toString() + "," + lat.toString(),
            // Geoapify's static-map zoom is 2x finer than the standard formula - corrected here.
            "zoom" => (zoom - 1.0).format("%.3f"),
            "width" => width.toString(),
            "height" => height.toString(),
            "format" => "png",
        };
        var options = {
            :dithering => Communications.IMAGE_DITHERING_FLOYD_STEINBERG,
        };
        Communications.makeImageRequest(
            BASE_URL,
            params,
            options,
            method(:_onReceive)
        );
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
                req[0] as Float,
                req[1] as Float,
                req[2] as Float,
                req[3] as Number,
                req[4] as Number,
                responseCode == 200 ? data : null
            );
        }
        var pending = _pending;
        if (pending != null) {
            _pending = null;
            _dispatch(
                pending[0] as Float,
                pending[1] as Float,
                pending[2] as Float,
                pending[3] as Number,
                pending[4] as Number
            );
        }
    }

    private function _ensureApiKeyLoaded() as Boolean {
        if (_apiKey != null) {
            return true;
        }
        var creds =
            WatchUi.loadResource(Rez.JsonData.Credentials) as Dictionary;
        var geoapify = creds["Geoapify"] as Dictionary;
        var key = geoapify["apiKey"];
        if (!(key instanceof String)) {
            return false;
        }
        _apiKey = key;
        return true;
    }
}
