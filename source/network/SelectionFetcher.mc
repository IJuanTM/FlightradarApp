import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Track (on select) and route (on full-detail open) lookups for the selected aircraft, on the map's shared request channel.
class SelectionFetcher {
    private const RETRY_DELAY_MS = 2000;
    private const ROUTE_CACHE_MAX = 8;
    private const AIRPORT_CACHE_MAX = 16;

    private var _selection as Selection;
    private var _tiles as MapTileClient;
    private var _trackClient as OpenSkyClient = new OpenSkyClient();
    private var _routeClient as RouteClient = new RouteClient();
    private var _airportClient as AirportClient = new AirportClient();

    private var _trackFetchInFlight as Boolean = false;
    private var _trackFetchStartMs as Number?;
    private var _trackFetchHex as String?;
    private var _trackFetchSeq as Number = 0;
    private var _trackFetchRetried as Boolean = false;
    // Set when _fetchTrack deferred because a map tile was already in flight - retried from retryDeferred.
    private var _trackFetchPending as Boolean = false;
    private var _trackRetryAtMs as Number?;

    // The pushed full-detail view, null when closed - route-fetch results only apply while this is still open.
    private var _detailView as AircraftDetailView?;
    private var _routeFetchInFlight as Boolean = false;
    private var _routeFetchStartMs as Number?;
    private var _routeFetchHex as String?;
    private var _routeFetchSeq as Number = 0;
    private var _routeFetchRetried as Boolean = false;
    // Set when _fetchRoute deferred because a map tile was already in flight - retried on the next tick.
    private var _routeFetchPending as Boolean = false;
    private var _routeRetryAtMs as Number?;
    private var _routeFetchCallsign as String?;
    // Routes and airports don't change within a session, so reopening a detail view needs no new lookups.
    private var _routeCache as Dictionary<String, [String?, String?]> = {};
    private var _airportCache as Dictionary<String, String> = {};
    // Departure/arrival lookups run independently and may overlap - AirportClient is stateless, with no timeout of its own.
    private var _airportFetchHex as String?;
    private var _pendingDepIcao as String?;
    private var _pendingArrIcao as String?;
    private var _airportFetchStartMs as Number?;

    public function initialize(selection as Selection, tiles as MapTileClient) {
        _selection = selection;
        _tiles = tiles;
    }

    public function isTrackLoading() as Boolean {
        return (
            _trackFetchInFlight || _trackFetchPending || _trackRetryAtMs != null
        );
    }

    public function onSelect() as Void {
        _trackFetchRetried = false;
        _trackRetryAtMs = null;
        _routeFetchRetried = false;
        _fetchTrack();
    }

    public function onDetailOpened(view as AircraftDetailView) as Void {
        _detailView = view;
        _routeFetchRetried = false;
        _routeRetryAtMs = null;
        _fetchRoute();
    }

    // Called from the detail view's onHide, so a late route result has nothing left to update.
    public function onDetailClosed() as Void {
        _detailView = null;
        // A deferred lookup would otherwise run from the tick for a view that's gone, holding the map paused meanwhile.
        _routeFetchPending = false;
        _routeRetryAtMs = null;
        if (!_routeFetchInFlight) {
            _tiles.resumeFor(:route);
        }
        _pendingDepIcao = null;
        _pendingArrIcao = null;
        _airportFetchStartMs = null;
    }

    public function retryDeferred() as Void {
        if (_trackFetchPending) {
            _fetchTrack();
        }
        var retryAt = _trackRetryAtMs;
        if (retryAt != null && System.getTimer() >= retryAt) {
            _trackRetryAtMs = null;
            _fetchTrack();
        }
        retryDeferredRoute();
    }

    public function retryDeferredRoute() as Void {
        if (_routeFetchPending) {
            _fetchRoute();
        }
        var retryAt = _routeRetryAtMs;
        if (retryAt != null && System.getTimer() >= retryAt) {
            _routeRetryAtMs = null;
            _fetchRoute();
        }
    }

    public function checkTimeouts(now as Number) as Void {
        if (
            _trackFetchInFlight and
            FetchTimeout.expired(_trackFetchStartMs, now)
        ) {
            _onTrackResult(
                _trackFetchSeq,
                _trackFetchHex as String,
                [],
                false,
                0
            );
        }
        checkRouteTimeouts(now);
    }

    // AirportClient itself has no timeout - synthesize the same "no info" fallback its own failure path produces.
    public function checkRouteTimeouts(now as Number) as Void {
        if (
            _routeFetchInFlight and
            FetchTimeout.expired(_routeFetchStartMs, now)
        ) {
            _onRouteResult(_routeFetchSeq, null, null, false, 0);
        }
        // && / ||, not and / or - the Prettier Monkey C formatter mis-prints (A or B) and C, flipping its meaning.
        if (
            (_pendingDepIcao != null || _pendingArrIcao != null) &&
            FetchTimeout.expired(_airportFetchStartMs, now)
        ) {
            if (_pendingDepIcao != null) {
                _onAirportInfoResult(_pendingDepIcao as String, null);
            }
            if (_pendingArrIcao != null) {
                _onAirportInfoResult(_pendingArrIcao as String, null);
            }
        }
    }

    private function _fetchTrack() as Void {
        var hex = _selection.hex;
        if (hex == null) {
            _trackFetchPending = false;
            _tiles.resumeFor(:track);
            return;
        }
        if (_trackFetchInFlight) {
            return;
        }
        if (_tiles.pauseAndCheckBusy(:track)) {
            _trackFetchPending = true;
            return;
        }
        _trackFetchPending = false;
        _trackFetchInFlight = true;
        _trackFetchStartMs = System.getTimer();
        _trackFetchHex = hex;
        _trackFetchSeq += 1;
        _trackClient.fetchTrack(
            _trackFetchSeq,
            hex as String,
            method(:_onTrackResult)
        );
    }

    public function _onTrackResult(
        requestId as Number,
        hex as String,
        points as Array<[Float, Float, Number, Boolean]>,
        ok as Boolean,
        code as Number
    ) as Void {
        if (requestId != _trackFetchSeq) {
            return;
        }
        _trackFetchInFlight = false;
        _tiles.resumeFor(:track);
        ApiStatus.setState(ApiStatus.track, ok);

        var stillSelected = _selection.isSelected(hex);

        if (stillSelected && ok) {
            _trackFetchRetried = false;
            _selection.track = points;
            _selection.trackHasHistory = points.size() > 0;
            var ac = _selection.aircraft;
            if (ac != null) {
                _selection.appendLivePoint(ac as Aircraft);
            }
        }

        // Genuine failure, not a stale selection - one retry so a single network blip doesn't stick forever.
        if (
            stillSelected &&
            !ok &&
            !_trackFetchRetried &&
            FetchTimeout.isTransient(code)
        ) {
            _trackFetchRetried = true;
            _trackRetryAtMs = System.getTimer() + RETRY_DELAY_MS;
        }

        if (!stillSelected) {
            // Selection changed mid-fetch - this result is stale, try the current selection instead.
            _fetchTrack();
        }

        WatchUi.requestUpdate();
    }

    private function _fetchRoute() as Void {
        var hex = _selection.hex;
        if (hex == null) {
            _routeFetchPending = false;
            _tiles.resumeFor(:route);
            var view = _detailView;
            if (view != null) {
                _showRouteUnavailable(view as AircraftDetailView);
            }
            return;
        }
        if (_routeFetchInFlight) {
            return;
        }
        var ac = _selection.aircraft;
        var callsign = ac != null ? (ac as Aircraft).flight : null;
        var cached = callsign != null ? _routeCache[callsign as String] : null;
        if (cached == null && _tiles.pauseAndCheckBusy(:route)) {
            _routeFetchPending = true;
            return;
        }
        _routeFetchPending = false;
        _routeFetchHex = hex;
        _routeFetchSeq += 1;
        if (cached != null) {
            // A lookup deferred before the cache filled still holds the map paused.
            _tiles.resumeFor(:route);
            _applyRoute(cached[0], cached[1], true, 200);
            return;
        }
        _routeFetchInFlight = true;
        _routeFetchStartMs = System.getTimer();
        _routeFetchCallsign = callsign;
        if (callsign == null) {
            // No callsign to look up by - same "no route found" outcome as a 404.
            _onRouteResult(_routeFetchSeq, null, null, true, 404);
            return;
        }
        _routeClient.fetchRoute(
            _routeFetchSeq,
            callsign as String,
            method(:_onRouteResult)
        );
    }

    public function _onRouteResult(
        requestId as Number,
        dep as String?,
        arr as String?,
        ok as Boolean,
        code as Number
    ) as Void {
        if (requestId != _routeFetchSeq) {
            return;
        }
        _routeFetchInFlight = false;
        _tiles.resumeFor(:route);
        ApiStatus.setState(ApiStatus.route, ok);
        var callsign = _routeFetchCallsign;
        if (ok && callsign != null) {
            if (_routeCache.size() >= ROUTE_CACHE_MAX) {
                _routeCache = {};
            }
            _routeCache[callsign] = [dep, arr];
        }
        _applyRoute(dep, arr, ok, code);
    }

    private function _applyRoute(
        dep as String?,
        arr as String?,
        ok as Boolean,
        code as Number
    ) as Void {
        var hex = _routeFetchHex as String;
        var view = _detailView;
        if (view == null) {
            return;
        }
        if (!_selection.isSelected(hex)) {
            if (_selection.hex != null) {
                // Reopened for a different aircraft mid-fetch - retry for what's actually showing.
                _fetchRoute();
            } else {
                _showRouteUnavailable(view as AircraftDetailView);
            }
            return;
        }

        if (ok) {
            _routeFetchRetried = false;
            _airportFetchHex = hex;
            _pendingDepIcao = dep;
            _pendingArrIcao = arr;
            if (dep != null) {
                _lookupAirport(dep as String);
            } else {
                (view as AircraftDetailView).setDepartureText(
                    DrawUtils.plainRuns("Unknown", Palette.ROUTE_DIM)
                );
            }
            // dep == arr (a touch-and-go) is already resolved or pending - one result fills both rows.
            if (arr != null) {
                if (dep == null || !(arr as String).equals(dep)) {
                    _lookupAirport(arr as String);
                }
            } else {
                (view as AircraftDetailView).setArrivalText(
                    DrawUtils.plainRuns("Unknown", Palette.ROUTE_DIM)
                );
            }
            return;
        }

        if (!_routeFetchRetried && FetchTimeout.isTransient(code)) {
            _routeFetchRetried = true;
            _routeRetryAtMs = System.getTimer() + RETRY_DELAY_MS;
            return;
        }
        _showRouteUnavailable(view as AircraftDetailView);
    }

    private function _lookupAirport(icao as String) as Void {
        var cached = _airportCache[icao];
        if (cached != null) {
            _applyAirportInfo(icao, cached);
            return;
        }
        _airportFetchStartMs = System.getTimer();
        _airportClient.fetchInfo(icao, method(:_onAirportInfoResult));
    }

    private function _showRouteUnavailable(view as AircraftDetailView) as Void {
        view.setDepartureText(
            DrawUtils.plainRuns("Unavailable", Palette.ROUTE_DIM)
        );
        view.setArrivalText(
            DrawUtils.plainRuns("Unavailable", Palette.ROUTE_DIM)
        );
    }

    public function _onAirportInfoResult(
        icao as String,
        text as String?
    ) as Void {
        ApiStatus.setState(ApiStatus.airportInfo, text != null);
        if (text != null) {
            if (_airportCache.size() >= AIRPORT_CACHE_MAX) {
                _airportCache = {};
            }
            _airportCache[icao] = text as String;
        }
        _applyAirportInfo(icao, text);
    }

    // Checks both pending slots - icao alone doesn't say dep vs arr (touch-and-go can have dep==arr).
    private function _applyAirportInfo(
        icao as String,
        text as String?
    ) as Void {
        var view = _detailView;
        if (view == null) {
            return;
        }
        if (!_selection.isSelected(_airportFetchHex)) {
            _pendingDepIcao = null;
            _pendingArrIcao = null;
            return;
        }

        // ICAO itself is still a resolved value even if the detail lookup failed.
        var segments =
            text != null
                ? DrawUtils.plainRuns(text as String, Palette.SUCCESS)
                : [
                      DrawUtils.plainRun(icao, Palette.SUCCESS),
                      DrawUtils.plainRun(" (no info)", Palette.ROUTE_DIM),
                  ] as Array<DrawUtils.ValueRun>;
        if (
            _pendingDepIcao != null &&
            (_pendingDepIcao as String).equals(icao)
        ) {
            _pendingDepIcao = null;
            (view as AircraftDetailView).setDepartureText(segments);
        }
        if (
            _pendingArrIcao != null &&
            (_pendingArrIcao as String).equals(icao)
        ) {
            _pendingArrIcao = null;
            (view as AircraftDetailView).setArrivalText(segments);
        }
    }
}
