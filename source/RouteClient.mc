import Toybox.Communications;
import Toybox.Lang;

// Callsign-keyed VRS standing data (tar1090's source) - works mid-flight, but gives the scheduled route, not a diversion.
class RouteClient {
    private const BASE_URL = "https://vrs-standing-data.adsb.lol/routes/";

    // requestId travels with the response - a late reply to a timed-out request must be told apart from its retry.
    typedef RouteCallback as
        (Method
            (
                requestId as Number,
                dep as String?,
                arr as String?,
                ok as Boolean
            ) as Void
        );

    public function initialize() {}

    public function fetchRoute(
        requestId as Number,
        callsign as String,
        callback as RouteCallback
    ) as Void {
        if (callsign.length() < 3) {
            callback.invoke(requestId, null, null, true);
            return;
        }
        Communications.makeWebRequest(
            BASE_URL + callsign.substring(0, 2) + "/" + callsign + ".json",
            null,
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :context => [requestId, callback] as [Number, RouteCallback],
            },
            method(:_onReceive)
        );
    }

    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null,
        context as [Number, RouteCallback]
    ) as Void {
        var requestId = context[0];
        var cb = context[1];
        // A 404 (unknown/uncrowdsourced callsign) is a normal outcome, not a failure - same as no route.
        if (responseCode == 404) {
            cb.invoke(requestId, null, null, true);
            return;
        }
        if (responseCode != 200 or !(data instanceof Lang.Dictionary)) {
            cb.invoke(requestId, null, null, false);
            return;
        }
        var airports = (data as Dictionary)["_airports"];
        if (
            !(airports instanceof Lang.Array) or
            (airports as Array).size() < 2
        ) {
            cb.invoke(requestId, null, null, true);
            return;
        }
        var list = airports as Array;
        cb.invoke(requestId, _icaoOf(list[0]), _icaoOf(list[1]), true);
    }

    private function _icaoOf(entry as Object?) as String? {
        if (!(entry instanceof Lang.Dictionary)) {
            return null;
        }
        var icao = (entry as Dictionary)["icao"];
        return icao instanceof Lang.String ? icao : null;
    }
}
