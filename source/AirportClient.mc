import Toybox.Communications;
import Toybox.Lang;

// Fetched on demand for departure/arrival ICAO codes, never polled. No auth, stateless, no in-flight guard needed.
class AirportClient {
    private const BASE_URL = "https://airport-data.com/api/ap_info.json";

    typedef InfoCallback as (Method(icao as String, text as String?) as Void);

    private var _callback as InfoCallback?;

    public function initialize() {}

    public function fetchInfo(
        icao as String,
        callback as InfoCallback
    ) as Void {
        _callback = callback;
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :context => icao,
        };
        Communications.makeWebRequest(
            BASE_URL,
            { "icao" => icao },
            options,
            method(:_onReceive)
        );
    }

    // Public so method(:_onReceive) isn't optimized away as an unreferenced private symbol.
    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null,
        context as String
    ) as Void {
        var cb = _callback;
        if (cb == null) {
            return;
        }
        if (responseCode != 200 or !(data instanceof Dictionary)) {
            cb.invoke(context, null);
            return;
        }

        var dict = data as Dictionary;
        var location = dict["location"];
        var country = dict["country"];
        var iata = dict["iata"];
        if (!(location instanceof String) or !(country instanceof String)) {
            cb.invoke(context, null);
            return;
        }

        var codes =
            iata instanceof String && (iata as String).length() > 0
                ? context + "/" + (iata as String)
                : context;
        var text =
            _asciiSanitize(_cleanLocation(location as String)) +
            ", " +
            _asciiSanitize(country as String) +
            " (" +
            codes +
            ")";
        cb.invoke(context, text);
    }

    // Some entries phrase location as "<municipality>, near <city>" - the city after "near" is more recognizable.
    private function _cleanLocation(location as String) as String {
        var idx = location.find("near ");
        if (idx == null) {
            return location;
        }
        return (
            location.substring((idx as Number) + 5, location.length()) as String
        );
    }

    // This app's fonts only bake in ASCII glyphs - drop anything else rather than risk a missing-glyph box.
    private function _asciiSanitize(s as String) as String {
        var chars = s.toCharArray();
        var out = "";
        for (var i = 0; i < chars.size(); i++) {
            var c = chars[i];
            if (c >= ' ' && c <= '~') {
                out += c.toString();
            }
        }
        return out;
    }
}
