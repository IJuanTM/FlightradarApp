import Toybox.Communications;
import Toybox.Lang;

class NearbyAirportsClient {
    private const BASE_URL = "https://api.core.openaip.net/api/airports";
    // Trims the response - full airport objects include runways/frequencies/etc, unused here.
    private const FIELDS = "name,icaoCode,iataCode,geometry";
    private const RESULT_LIMIT = 30;

    // [icao, label, isSmall, lat, lon] - icao is the identity key, label is drawn (IATA when present), isSmall = no IATA code.
    typedef NearbyAirport as [String, String, Boolean, Float, Float];

    typedef NearbyAirportsCallback as
        (Method(airports as Array<NearbyAirport>, ok as Boolean) as Void);

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
            _resolve([] as Array<NearbyAirport>, false);
            return;
        }

        var payload = _slot.activePayload() as Array;

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
            _resolve([] as Array<NearbyAirport>, false);
            return;
        }

        var items = (data as Dictionary)["items"];
        if (!(items instanceof Lang.Array)) {
            _resolve([] as Array<NearbyAirport>, false);
            return;
        }
        var result = [] as Array<NearbyAirport>;
        for (var i = 0; i < items.size(); i++) {
            var airport = _parseItem(items[i]);
            if (airport != null) {
                result.add(airport as NearbyAirport);
            }
        }
        _resolve(result, true);
    }

    // GeoJSON "coordinates" is [lon, lat], the opposite order from the "pos" query param above.
    private function _parseItem(entry as Object?) as NearbyAirport? {
        if (!(entry instanceof Lang.Dictionary)) {
            return null;
        }
        var dict = entry as Dictionary;
        var icao = dict["icaoCode"];
        if (!(icao instanceof Lang.String)) {
            return null;
        }
        // IATA (3-char) is more widely recognized than ICAO (4-char) - prefer it when present.
        var iata = dict["iataCode"];
        var hasIata =
            iata instanceof Lang.String && (iata as String).length() > 0;
        var label = hasIata ? iata as String : icao as String;

        var geometry = dict["geometry"];
        if (!(geometry instanceof Lang.Dictionary)) {
            return null;
        }
        var coords = (geometry as Dictionary)["coordinates"];
        if (!(coords instanceof Lang.Array) or (coords as Array).size() < 2) {
            return null;
        }
        var lon = JsonUtil.toFloatOrNull((coords as Array)[0]);
        var lat = JsonUtil.toFloatOrNull((coords as Array)[1]);
        if (lat == null or lon == null) {
            return null;
        }

        return (
            [icao as String, label, !hasIata, lat as Float, lon as Float] as
            NearbyAirport
        );
    }

    private function _resolve(
        airports as Array<NearbyAirport>,
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
