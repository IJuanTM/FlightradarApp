import Toybox.Communications;
import Toybox.Lang;

// Airports within a radius (OpenAIP Core API, key required) - unlike RouteClient/AirportClient, not
// keyed by a known code.
class NearbyAirportsClient {
    private const BASE_URL = "https://api.core.openaip.net/api/airports";
    // Trims the response - full airport objects include runways/frequencies/etc, unused here.
    private const FIELDS = "name,icaoCode,geometry";
    private const RESULT_LIMIT = 30;

    typedef NearbyAirportsCallback as
        (Method
            (airports as Array<[String, Float, Float]>, ok as Boolean) as Void
        );

    // Payload is [lat, lon, radiusMeters] - see PendingRequestSlot for the active/queued contract.
    private var _slot as PendingRequestSlot = new PendingRequestSlot();
    private var _apiKey as String?;

    public function initialize() {}

    public function fetchNearby(
        lat as Float,
        lon as Float,
        radiusMeters as Number,
        callback as NearbyAirportsCallback
    ) as Void {
        if (!_slot.start([lat, lon, radiusMeters], callback as Method)) {
            return;
        }
        _performFetch();
    }

    private function _performFetch() as Void {
        if (!_ensureApiKeyLoaded()) {
            _resolve([] as Array<[String, Float, Float]>, false);
            return;
        }

        var payload = _slot.activePayload() as Array;

        // No :responseType - trusts the platform to auto-detect from the response's Content-Type.
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "x-openaip-api-key" => _apiKey },
        };

        Communications.makeWebRequest(
            BASE_URL,
            {
                "pos" => (payload[0] as Float).toString() +
                "," +
                (payload[1] as Float).toString(),
                "dist" => (payload[2] as Number).toString(),
                "limit" => RESULT_LIMIT.toString(),
                "fields" => FIELDS,
            },
            options,
            method(:_onReceive)
        );
    }

    private function _ensureApiKeyLoaded() as Boolean {
        if (_apiKey != null) {
            return true;
        }
        var values = CredentialsUtil.loadStrings("OpenAIP", ["apiKey"]);
        if (values == null) {
            return false;
        }
        _apiKey = values[0];
        return true;
    }

    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode != 200 or !(data instanceof Lang.Dictionary)) {
            _resolve([] as Array<[String, Float, Float]>, false);
            return;
        }

        var items = (data as Dictionary)["items"];
        var result = [] as Array<[String, Float, Float]>;
        if (items instanceof Lang.Array) {
            var arr = items as Array;
            for (var i = 0; i < arr.size(); i++) {
                var airport = _parseItem(arr[i]);
                if (airport != null) {
                    result.add(airport as [String, Float, Float]);
                }
            }
        }
        _resolve(result, true);
    }

    // GeoJSON "coordinates" is [lon, lat], the opposite order from the "pos" query param above.
    private function _parseItem(entry as Object?) as [String, Float, Float]? {
        if (!(entry instanceof Lang.Dictionary)) {
            return null;
        }
        var dict = entry as Dictionary;
        var icao = dict["icaoCode"];
        if (!(icao instanceof Lang.String)) {
            return null;
        }

        var geometry = dict["geometry"];
        if (!(geometry instanceof Lang.Dictionary)) {
            return null;
        }
        var coords = (geometry as Dictionary)["coordinates"];
        if (!(coords instanceof Lang.Array) or (coords as Array).size() < 2) {
            return null;
        }
        var lon = (coords as Array)[0];
        var lat = (coords as Array)[1];
        if (!_isNumeric(lat) or !_isNumeric(lon)) {
            return null;
        }

        return (
            [icao as String, lat.toFloat(), lon.toFloat()] as
            [String, Float, Float]
        );
    }

    // Excludes only the types with no .toFloat() (Dictionary/Array/Boolean).
    private function _isNumeric(v) as Boolean {
        return (
            v != null and
            !(
                v instanceof Lang.Dictionary or
                v instanceof Lang.Array or
                v instanceof Lang.Boolean
            )
        );
    }

    // Delivers to the active request's own callback before promoting any queued request.
    private function _resolve(
        airports as Array<[String, Float, Float]>,
        ok as Boolean
    ) as Void {
        var cb = _slot.activeCallback() as NearbyAirportsCallback?;
        var promoted = _slot.clearAndPromote();
        if (cb != null) {
            cb.invoke(airports, ok);
        }
        if (promoted) {
            _performFetch();
        }
    }
}
