import Toybox.Communications;
import Toybox.Lang;

// Free, no-auth, stateless route lookup keyed by callsign (VRS standing data, same source tar1090 uses) -
// not by flight instance like OpenSky's /flights/aircraft, so this also works for an in-progress flight.
// Reflects the scheduled route for that callsign, not a live diversion.
class RouteClient {
    private const BASE_URL = "https://vrs-standing-data.adsb.lol/routes/";

    // hex identifies which aircraft this request was for - callers must not rely on their own mutable
    // state to correlate a response, since a retried/late response can otherwise get misattributed.
    typedef RouteCallback as
        (Method
            (
                hex as String,
                dep as String?,
                arr as String?,
                ok as Boolean
            ) as Void
        );

    public function initialize() {}

    public function fetchRoute(
        hex as String,
        callsign as String,
        callback as RouteCallback
    ) as Void {
        if (callsign.length() < 3) {
            callback.invoke(hex, null, null, true);
            return;
        }
        var url =
            BASE_URL + callsign.substring(0, 2) + "/" + callsign + ".json";
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :context => [hex, callback] as [String, RouteCallback],
        };
        Communications.makeWebRequest(url, null, options, method(:_onReceive));
    }

    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null,
        context as [String, RouteCallback]
    ) as Void {
        var hex = context[0];
        var cb = context[1];
        // A 404 (unknown/uncrowdsourced callsign) is a normal outcome, not a failure - same as no route.
        if (responseCode == 404) {
            cb.invoke(hex, null, null, true);
            return;
        }
        if (responseCode != 200 or !(data instanceof Lang.Dictionary)) {
            cb.invoke(hex, null, null, false);
            return;
        }
        var airports = (data as Dictionary)["_airports"];
        if (
            !(airports instanceof Lang.Array) or
            (airports as Array).size() < 2
        ) {
            cb.invoke(hex, null, null, true);
            return;
        }
        var list = airports as Array;
        cb.invoke(hex, _icaoOf(list[0]), _icaoOf(list[1]), true);
    }

    private function _icaoOf(entry as Object?) as String? {
        if (!(entry instanceof Lang.Dictionary)) {
            return null;
        }
        var icao = (entry as Dictionary)["icao"];
        return icao instanceof Lang.String ? icao : null;
    }
}
