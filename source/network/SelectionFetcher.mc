import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Track (on select) and route (on full-detail open) lookups for the selected aircraft, on the map's shared request channel.
class SelectionFetcher {
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

    // The pushed full-detail view, null when closed - route-fetch results only apply while this is still open.
    private var _detailView as AircraftDetailView?;
    private var _routeFetchInFlight as Boolean = false;
    private var _routeFetchStartMs as Number?;
    private var _routeFetchHex as String?;
    private var _routeFetchSeq as Number = 0;
    private var _routeFetchRetried as Boolean = false;
    // Set when _fetchRoute deferred because a map tile was already in flight - retried on the next tick.
    private var _routeFetchPending as Boolean = false;
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
        return _trackFetchInFlight || _trackFetchPending;
    }

    public function onSelect() as Void {
        _trackFetchRetried = false;
        _routeFetchRetried = false;
        _fetchTrack();
    }

    public function onDetailOpened(view as AircraftDetailView) as Void {
        _detailView = view;
        _routeFetchRetried = false;
        _fetchRoute();
    }

    // Called from the detail view's onHide, so a late route result has nothing left to update.
    public function onDetailClosed() as Void {
        _detailView = null;
        // A deferred lookup would otherwise run from the tick for a view that's gone, holding the map paused meanwhile.
        _routeFetchPending = false;
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
        retryDeferredRoute();
    }

    public function retryDeferredRoute() as Void {
        if (_routeFetchPending) {
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
                false
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
            _onRouteResult(_routeFetchSeq, null, null, false);
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
        ok as Boolean
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
        if (stillSelected && !ok && !_trackFetchRetried) {
            _trackFetchRetried = true;
            _fetchTrack();
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
            return;
        }
        if (_routeFetchInFlight) {
            return;
        }
        if (_tiles.pauseAndCheckBusy(:route)) {
            _routeFetchPending = true;
            return;
        }
        _routeFetchPending = false;
        _routeFetchInFlight = true;
        _routeFetchStartMs = System.getTimer();
        _routeFetchHex = hex;
        _routeFetchSeq += 1;
        var ac = _selection.aircraft;
        var callsign = ac != null ? (ac as Aircraft).flight : null;
        if (callsign == null) {
            // No callsign to look up by - same "no route found" outcome as a 404.
            _onRouteResult(_routeFetchSeq, null, null, true);
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
        ok as Boolean
    ) as Void {
        if (requestId != _routeFetchSeq) {
            return;
        }
        var hex = _routeFetchHex as String;
        _routeFetchInFlight = false;
        _tiles.resumeFor(:route);
        ApiStatus.setState(ApiStatus.route, ok);

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
                _airportFetchStartMs = System.getTimer();
                _airportClient.fetchInfo(
                    dep as String,
                    method(:_onAirportInfoResult)
                );
            } else {
                (view as AircraftDetailView).setDepartureText(
                    DrawUtils.plainRuns("Unknown", Palette.ROUTE_DIM)
                );
            }
            if (arr != null) {
                _airportFetchStartMs = System.getTimer();
                _airportClient.fetchInfo(
                    arr as String,
                    method(:_onAirportInfoResult)
                );
            } else {
                (view as AircraftDetailView).setArrivalText(
                    DrawUtils.plainRuns("Unknown", Palette.ROUTE_DIM)
                );
            }
            return;
        }

        if (!_routeFetchRetried) {
            _routeFetchRetried = true;
            _fetchRoute();
            return;
        }
        _showRouteUnavailable(view as AircraftDetailView);
    }

    private function _showRouteUnavailable(view as AircraftDetailView) as Void {
        view.setDepartureText(
            DrawUtils.plainRuns("Unavailable", Palette.ROUTE_DIM)
        );
        view.setArrivalText(
            DrawUtils.plainRuns("Unavailable", Palette.ROUTE_DIM)
        );
    }

    // Checks both pending slots - icao alone doesn't say dep vs arr (touch-and-go can have dep==arr).
    public function _onAirportInfoResult(
        icao as String,
        text as String?
    ) as Void {
        ApiStatus.setState(ApiStatus.airportInfo, text != null);
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
