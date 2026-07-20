import Toybox.Communications;
import Toybox.Lang;

// Free, no-auth, static route lookup keyed by callsign (VRS standing data, the same source tar1090 itself
// uses for route display) - not by flight instance, so unlike OpenSky's /flights/aircraft (batch-processed
// overnight, only ever the last *completed* flight) this also works for a flight still in progress.
// Reflects the usual/scheduled route for that flight number, not a live diversion - a real but much rarer
// failure mode than showing a different flight entirely. No in-flight guard needed - stateless per fetch.
class RouteClient {
    private const BASE_URL = "https://vrs-standing-data.adsb.lol/routes/";

    typedef RouteCallback as
        (Method(dep as String?, arr as String?, ok as Boolean) as Void);

    public function initialize() {}

    public function fetchRoute(
        callsign as String,
        callback as RouteCallback
    ) as Void {
        if (callsign.length() < 3) {
            callback.invoke(null, null, true);
            return;
        }
        var url =
            BASE_URL + callsign.substring(0, 2) + "/" + callsign + ".json";
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
            :context => callback,
        };
        Communications.makeWebRequest(url, null, options, method(:_onReceive));
    }

    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null,
        context as RouteCallback
    ) as Void {
        // A 404 (unknown/uncrowdsourced callsign) is a normal outcome, not a failure - same as no route.
        if (responseCode == 404) {
            context.invoke(null, null, true);
            return;
        }
        if (responseCode != 200 or !(data instanceof Dictionary)) {
            context.invoke(null, null, false);
            return;
        }
        var airports = (data as Dictionary)["_airports"];
        if (!(airports instanceof Array) or (airports as Array).size() < 2) {
            context.invoke(null, null, true);
            return;
        }
        var list = airports as Array;
        context.invoke(_icaoOf(list[0]), _icaoOf(list[1]), true);
    }

    private function _icaoOf(entry as Object?) as String? {
        if (!(entry instanceof Dictionary)) {
            return null;
        }
        var icao = (entry as Dictionary)["icao"];
        return icao instanceof String ? icao : null;
    }
}
