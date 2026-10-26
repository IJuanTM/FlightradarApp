import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Fixed background reference points, not aircraft - own simple pass, no declutter reservation.
class NearbyAirports {
    // Airports basically never change - a long cooldown is fair use of the free OpenAIP tier.
    private const MIN_REFETCH_INTERVAL_MS = 20000;
    private const REFETCH_MARGIN_FACTOR = 0.5;
    private const OVERSCAN_FACTOR = 1.2;
    // Least recently fetched evicted first past this - keeps the merged cache bounded on a long panning session.
    private const CACHE_MAX = 150;
    private const MARKER_R = 3;
    private const MARKER_R_SMALL = 2;
    private const SMALL_DIM_FACTOR = 0.75;
    private const LABEL_GAP = 2;

    private var _client as NearbyAirportsClient = new NearbyAirportsClient();
    // Merged, never replaced, per fetch - airports don't move, so one seen once stays drawable after the view moves on.
    private var _airports as Array<NearbyAirportsClient.NearbyAirport> = [];
    private var _requestedLat as Float?;
    private var _requestedLon as Float?;
    private var _requestedRadiusKm as Float?;
    private var _nextFetchAtMs as Number?;
    private var _font as Graphics.FontType = Graphics.FONT_XTINY;

    public function initialize() {}

    public function onLayout(font as Graphics.FontType) as Void {
        _font = font;
    }

    public function maybeFetch(
        focusLat as Float,
        focusLon as Float,
        radiusKm as Float
    ) as Void {
        var now = System.getTimer();
        var nextFetchAt = _nextFetchAtMs;
        if (nextFetchAt != null and now < (nextFetchAt as Number)) {
            return;
        }

        var requestedLat = _requestedLat;
        if (
            requestedLat != null and
            _requestedRadiusKm == radiusKm and
            Projection.distanceKm(
                requestedLat as Float,
                _requestedLon as Float,
                focusLat,
                focusLon
            ) <=
                radiusKm * REFETCH_MARGIN_FACTOR
        ) {
            return;
        }

        _requestedLat = focusLat;
        _requestedLon = focusLon;
        _requestedRadiusKm = radiusKm;
        _nextFetchAtMs = now + MIN_REFETCH_INTERVAL_MS;
        _client.fetchNearby(
            focusLat,
            focusLon,
            (radiusKm * 1000 * OVERSCAN_FACTOR).toNumber(),
            method(:_onResult)
        );
    }

    public function _onResult(
        airports as Array<NearbyAirportsClient.NearbyAirport>,
        ok as Boolean
    ) as Void {
        ApiStatus.setState(ApiStatus.airports, ok);
        if (ok) {
            var fetched = ({}) as Dictionary<String, Boolean>;
            for (var i = 0; i < airports.size(); i++) {
                fetched[airports[i][0]] = true;
            }
            var merged = [] as Array<NearbyAirportsClient.NearbyAirport>;
            for (var i = 0; i < _airports.size(); i++) {
                var cached = _airports[i];
                if (!fetched.hasKey(cached[0])) {
                    merged.add(cached);
                }
            }
            merged.addAll(airports);
            var excess = merged.size() - CACHE_MAX;
            _airports = excess > 0 ? merged.slice(excess, null) : merged;
            WatchUi.requestUpdate();
        } else {
            // Otherwise the refetch-margin check suppresses every retry until the view moves.
            _requestedLat = null;
        }
    }

    public function draw(dc as Dc, proj as ScreenProjection) as Void {
        var showSmall = Settings.showSmallAirports;
        var smallColor = DrawUtils.dimColor(Palette.AIRPORT, SMALL_DIM_FACTOR);
        for (var i = 0; i < _airports.size(); i++) {
            var airport = _airports[i];
            var isSmall = airport[2] as Boolean;
            if (!showSmall && isSmall) {
                continue;
            }
            var pos = proj.toScreen(airport[3] as Float, airport[4] as Float);
            if (!DrawUtils.insideCircle(pos, proj.cx, proj.cy, proj.radiusPx)) {
                continue;
            }
            var markerR = isSmall ? MARKER_R_SMALL : MARKER_R;
            dc.setColor(
                isSmall ? smallColor : Palette.AIRPORT,
                Graphics.COLOR_TRANSPARENT
            );
            dc.fillCircle(pos[0], pos[1], markerR);
            dc.drawText(
                pos[0],
                pos[1] + markerR + LABEL_GAP,
                _font,
                airport[1] as String,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }
    }
}
