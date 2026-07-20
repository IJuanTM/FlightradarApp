import Toybox.Communications;
import Toybox.Lang;

// Fetched on demand for departure/arrival ICAO codes, never polled. No auth, stateless, no in-flight guard needed.
class AirportClient {
    private const BASE_URL = "https://airport-data.com/api/ap_info.json";

    typedef InfoCallback as (Method(icao as String, text as String?) as Void);

    public function initialize() {}

    // Callback travels via :context, not an instance field - stays stateless across concurrent fetches.
    public function fetchInfo(
        icao as String,
        callback as InfoCallback
    ) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :context => [icao, callback] as [String, InfoCallback],
        };
        Communications.makeWebRequest(
            BASE_URL,
            { "icao" => icao },
            options,
            method(:_onReceive)
        );
    }

    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null,
        context as [String, InfoCallback]
    ) as Void {
        var icao = context[0];
        var cb = context[1];
        if (responseCode != 200 or !(data instanceof Dictionary)) {
            cb.invoke(icao, null);
            return;
        }

        var dict = data as Dictionary;
        var location = dict["location"];
        var country = dict["country"];
        var iata = dict["iata"];
        if (!(location instanceof String) or !(country instanceof String)) {
            cb.invoke(icao, null);
            return;
        }

        var codes =
            iata instanceof String && (iata as String).length() > 0
                ? icao + "/" + (iata as String)
                : icao;
        var text =
            TextUtil.foldDiacritics(_cleanLocation(location as String)) +
            ", " +
            TextUtil.foldDiacritics(country as String) +
            " (" +
            codes +
            ")";
        cb.invoke(icao, text);
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
}
