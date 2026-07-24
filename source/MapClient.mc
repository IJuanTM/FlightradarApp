import Toybox.Communications;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.WatchUi;

// Fetches a static background-map image from Geoapify (OSM data, dark-matter style), one request at a time.
class MapClient {
    private const BASE_URL = "https://maps.geoapify.com/v1/staticmap";
    private const STYLE = "dark-matter";

    private var _apiKey as String?;
    private var _fetchInFlight as Boolean = false;

    typedef MapCallback as
        (Method
            (
                bitmap as
                    Graphics.BitmapReference or WatchUi.BitmapResource or Null
            ) as Void
        );
    private var _pendingCallback as MapCallback?;

    public function initialize() {}

    public function isFetchInFlight() as Boolean {
        return _fetchInFlight;
    }

    public function fetchMap(
        lat as Float,
        lon as Float,
        zoom as Float,
        widthPx as Number,
        heightPx as Number,
        callback as MapCallback
    ) as Void {
        if (_fetchInFlight) {
            return;
        }
        if (!_ensureApiKeyLoaded()) {
            callback.invoke(null);
            return;
        }

        _fetchInFlight = true;
        _pendingCallback = callback;

        var params = {
            "style" => STYLE,
            "width" => widthPx,
            "height" => heightPx,
            "center" => "lonlat:" + lon.toString() + "," + lat.toString(),
            "zoom" => zoom,
            "format" => "png",
            "apiKey" => _apiKey,
        };
        Communications.makeImageRequest(
            BASE_URL,
            params,
            {
                :maxWidth => widthPx,
                :maxHeight => heightPx,
                :dithering => Communications.IMAGE_DITHERING_NONE,
            },
            method(:_onReceive)
        );
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

    public function _onReceive(
        responseCode as Number,
        data as WatchUi.BitmapResource or Graphics.BitmapReference or Null
    ) as Void {
        _fetchInFlight = false;
        var cb = _pendingCallback;
        _pendingCallback = null;
        if (cb == null) {
            return;
        }
        cb.invoke(responseCode == 200 ? data : null);
    }
}
