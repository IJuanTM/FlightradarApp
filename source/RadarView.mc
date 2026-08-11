import Toybox.Activity;
import Toybox.Application.Storage;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

const APP_VERSION = "0.14.2";

// Sorts needed tiles by on-screen visible area; the center-of-screen tile is always pinned first.
class TileVisibilityComparator {
    private var _centerTx as Number;
    private var _centerTy as Number;
    private var _tileZ as Number;
    private var _focusLat as Float;
    private var _focusLon as Float;
    private var _cx as Number;
    private var _cy as Number;
    private var _radiusPx as Number;
    private var _radiusKm as Float;
    private var _screenW as Number;
    private var _screenH as Number;

    public function initialize(
        centerTx as Number,
        centerTy as Number,
        tileZ as Number,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        screenW as Number,
        screenH as Number
    ) {
        _centerTx = centerTx;
        _centerTy = centerTy;
        _tileZ = tileZ;
        _focusLat = focusLat;
        _focusLon = focusLon;
        _cx = cx;
        _cy = cy;
        _radiusPx = radiusPx;
        _radiusKm = radiusKm;
        _screenW = screenW;
        _screenH = screenH;
    }

    public function compare(a as Object, b as Object) as Number {
        var ta = a as [Number, Number, Number, Number];
        var tb = b as [Number, Number, Number, Number];
        var aIsCenter = ta[1] == _centerTx and ta[2] == _centerTy;
        var bIsCenter = tb[1] == _centerTx and tb[2] == _centerTy;
        if (aIsCenter and !bIsCenter) {
            return -1;
        }
        if (bIsCenter and !aIsCenter) {
            return 1;
        }
        var areaDiff = _visibleArea(tb[1], tb[2]) - _visibleArea(ta[1], ta[2]);
        return areaDiff > 0 ? 1 : areaDiff < 0 ? -1 : 0;
    }

    private function _visibleArea(tx as Number, ty as Number) as Float {
        var topLeftLatLon = Projection.tileToLatLon(tx, ty, _tileZ);
        var bottomRightLatLon = Projection.tileToLatLon(tx + 1, ty + 1, _tileZ);
        var topLeft = Projection.toScreenF(
            _focusLat,
            _focusLon,
            topLeftLatLon[0],
            topLeftLatLon[1],
            _cx,
            _cy,
            _radiusPx,
            _radiusKm
        );
        var bottomRight = Projection.toScreenF(
            _focusLat,
            _focusLon,
            bottomRightLatLon[0],
            bottomRightLatLon[1],
            _cx,
            _cy,
            _radiusPx,
            _radiusKm
        );
        var overlapW = _clampPositive(
            _min(bottomRight[0], _screenW.toFloat()) - _max(topLeft[0], 0.0)
        );
        var overlapH = _clampPositive(
            _min(bottomRight[1], _screenH.toFloat()) - _max(topLeft[1], 0.0)
        );
        return overlapW * overlapH;
    }

    private function _min(a as Float, b as Float) as Float {
        return a < b ? a : b;
    }

    private function _max(a as Float, b as Float) as Float {
        return a > b ? a : b;
    }

    private function _clampPositive(v as Float) as Float {
        return v > 0.0 ? v : 0.0;
    }
}

class RadarView extends WatchUi.View {
    // Indexed alongside Settings.ZOOM_LEVELS_KM - slower at wide zoom, where responses risk the platform's size ceiling.
    private const POLL_MS_BY_ZOOM as Array<Number> = [1000, 1000, 2000, 3000];
    // Multiplies POLL_MS_BY_ZOOM in battery saver mode - fewer fetches, not a different schedule.
    private const BATTERY_SAVER_MULTIPLIER = 3;
    private const MAX_SELECTED_MISSES = 3;
    // 4 gives 1/2/3/4, 2/4/6/8, 5/10/15/20, 10/20/30/40 - a divisor of 3 gave an ugly 3/6/9 at 10km.
    private const RING_TARGET_COUNT = 4;
    // Wider than the icon - real taps land less precisely than a mouse click.
    private const HIT_RADIUS_PX = 24;
    private const DRAG_THRESHOLD_PX = 32;
    // Only bounds ongoing growth, never the initial OpenSky history.
    private const MAX_SELECTED_TRACK_POINTS = 500;

    // Measured once in onLayout from the monospace font - same _charW pattern as ../TerminalWatchface.
    private var _charW as Number = 8;
    private var _charH as Number = 14;
    private var _edgeMargin as Number = 20;

    // Same shade steps as ../TerminalWatchface's GRAYS, extended with two lighter steps for this app's own use.
    private const GRAYS =
        [0x111111, 0x333333, 0x555555, 0x777777, 0xaaaaaa, 0xcccccc] as
        Array<Number>;
    private const COLOR_RING = DrawUtil.COLOR_RING;
    private const COLOR_RING_ALPHA = DrawUtil.ALPHA_25;
    private const COLOR_BOUNDARY_ALPHA = DrawUtil.COLOR_BOUNDARY_ALPHA;
    private const COLOR_TICK_ALPHA = DrawUtil.ALPHA_55;
    private const COLOR_MINOR_TICK_ALPHA = DrawUtil.ALPHA_35;
    private const COLOR_GRID = GRAYS[3];
    private const COLOR_GRID_ALPHA = DrawUtil.ALPHA_15;
    private const COLOR_GRID_LABEL = GRAYS[2];
    private var _gridLabelInset as Number = 22;
    private var _topPanelLineHeight as Number = 18;
    private var _detailPanelLineHeight as Number = 18;
    private const COLOR_TRAIL_ALPHA = DrawUtil.ALPHA_95;
    private const COLOR_TEXT = GRAYS[5];

    // Identical to ../TerminalWatchface's own COLORS array - every accent below indexes into this, not a hand-picked hex.
    private const COLORS =
        [
            0xffffff, // 0  white
            0x55ff77, // 1  green
            0x55ffff, // 2  cyan
            0xffee55, // 3  yellow
            0xff9944, // 4  orange
            0xff5555, // 5  red
            0x6699ff, // 6  blue
            0xff55ff, // 7  magenta
            0x777777, // 8  light grey (unused here - GRAYS covers structural chrome instead)
            0xaa77ff, // 9  purple
        ] as Array<Number>;

    private const COLOR_USER = COLORS[2]; // cyan
    // Not magenta (disliked) - green contrasts well against white, the default aircraft color.
    private const COLOR_SELECTED = COLORS[1]; // green
    private const COLOR_EMERGENCY = COLORS[5]; // red

    private const COLOR_AIRCRAFT_DEFAULT = COLORS[0]; // white
    private const COLOR_AIRCRAFT_LIGHT = COLORS[3]; // yellow
    private const COLOR_AIRCRAFT_HEAVY = COLORS[6]; // blue
    private const COLOR_AIRCRAFT_FAST = COLORS[9]; // purple
    private const COLOR_HELICOPTER = COLORS[4]; // orange
    private const COLOR_MILITARY = COLORS[7]; // magenta

    // "Grey" full-detail values are white - label and value would read as the same dim tone otherwise.
    private const COLOR_DETAIL_VALUE = COLORS[0]; // white
    // Route's loading/unknown/failed states only, to read as "not resolved" rather than a fact.
    private const COLOR_ROUTE_DIM = COLOR_GRID_LABEL;
    // Identity/reference fields - not grey, row labels are already grey.
    private const COLOR_IDENTITY = COLORS[2]; // cyan
    private const COLOR_ENV = COLORS[9]; // purple

    // Detail panel value colors - not tied to aircraft category, just distinguishing fields at a glance.
    private const COLOR_ALT = COLORS[6]; // blue
    private const COLOR_SPEED = COLORS[3]; // yellow
    // Orange, not cyan - would collide with COLOR_IDENTITY (also cyan).
    private const COLOR_HDG = COLORS[4]; // orange
    private const COLOR_SQUAWK = COLORS[7]; // magenta
    // Shared status semantics across top/detail panels: green = done/good, orange = caution.
    private const COLOR_SUCCESS = COLORS[1]; // green
    private const COLOR_WARN = COLORS[4]; // orange

    // Indexed alongside Settings.ZOOM_LEVELS_KM - real round-number distances, not derived from it.
    private const GRID_STEP_KM as Array<Float> = [1.0, 5.0, 10.0, 25.0];

    // Persisted on real app exit so a future cold app-open (currentLocation gone stale) still has a seed.
    private const STORAGE_KEY_LAT = "lastKnownLat";
    private const STORAGE_KEY_LON = "lastKnownLon";
    private const STORAGE_KEY_TS = "lastKnownTs";
    // Beyond this, a stored fix is more likely to be a stale "hours ago" location than close to
    // wherever the user is now - better to wait for a real fix than fetch data for the old spot.
    private const MAX_STORED_POSITION_AGE_SEC = 900;

    private var _centerLat as Float?;
    private var _centerLon as Float?;
    private var _hasFix as Boolean = false;
    // Only set by a real GPS fix (onPosition), never by _tryLastKnownPosition()'s fallback seeds.
    private var _liveFixAtSec as Number?;

    private var _aircraft as Array<Aircraft> = [];
    private var _aircraftByHex as Dictionary<String, Aircraft> = {};
    private var _lastFetchOk as Boolean = true;
    private var _lastFetchTooMuchData as Boolean = false;
    // True once the current view (location/zoom) has a successful fetch - reset on pan/zoom so the
    // status text shows "Fetching" for a genuine new-view load, not a same-view background poll.
    private var _viewHasFreshData as Boolean = false;
    private var _fetchInFlight as Boolean = false;
    // Asked to fetch again while one was already in flight - retried once it resolves.
    private var _refetchPending as Boolean = false;
    private var _fetchStartMs as Number?;
    // 10s - ordinary round trips through the phone relay routinely take 3-9s; a lower value flashed "No Signal" on normal latency, not just genuine failures.
    private const FETCH_TIMEOUT_MS = 10000;
    // One-shot retry delay for a route fetch deferred at detail-open time - see openFullDetail().
    private const ROUTE_RETRY_AFTER_HIDE_MS = 1000;
    private var _lastDrawnPositions as Array<[String, Number, Number]> = [];
    // [hex, x0, y0, x1, y1] - hex-tagged so a label may overlap its own icon/chevron/reticle, only another's clips.
    private var _reservedRects as
        Array<[String, Number, Number, Number, Number]> = [];
    // hex -> [category, shapeKey, sizeScale, iconHalfExtent] - cleared whenever aircraft
    // data changes (_onFetchResult), not every redraw - see _classify().
    private var _classifyCache as
        Dictionary<String, [String, String, Float, Number]> = {};
    // Same idea as _classifyCache, for the compact detail panel's built segments - see _buildDetailLinesCached.
    private var _detailLinesCache as Array<Array<DrawUtil.ValueRun> >?;
    private var _detailLinesCacheHex as String?;
    // [singleColorMode, useMetricUnits] - both affect the built output but aren't tied to any poll/fetch.
    private var _detailLinesCacheFlags as [Boolean, Boolean]?;
    // Same idea again, for every visible aircraft's on-map label - see _buildLabelLinesCached.
    private var _labelLinesCache as
        Dictionary<
            String,
            [Array<DrawUtil.ValueRun>, Array<DrawUtil.ValueRun>]
        > = {};
    // [showCallsign, showSpeed, showAltitude, singleColorMode, useMetricUnits].
    private var _labelLinesCacheFlags as
        [Boolean, Boolean, Boolean, Boolean, Boolean]?;

    private var _selectedHex as String?;
    // [lat, lon, altitudeFt, onGround] - altitude/ground drive the trail's gradient/dashed rendering.
    private var _selectedTrack as Array<[Float, Float, Number, Boolean]> = [];
    private var _trackFetchInFlight as Boolean = false;
    private var _trackFetchStartMs as Number?;
    private var _trackFetchHex as String?;
    private var _trackHasHistory as Boolean = false;
    private var _selectedMissCount as Number = 0;
    private var _trackFetchRetried as Boolean = false;
    // Set when _fetchSelectedTrack deferred because a map tile was already in flight - retried from _onTick.
    private var _trackFetchPending as Boolean = false;
    // Last confirmed position of the selected aircraft - frozen-camera fallback on auto-deselect, see _onFetchResult.
    private var _selectedLastPos as [Float, Float]?;

    // The pushed full-detail view, null when closed - route-fetch results only apply while this is still open.
    private var _detailView as AircraftDetailView?;
    private var _routeFetchInFlight as Boolean = false;
    private var _routeFetchStartMs as Number?;
    private var _routeFetchHex as String?;
    private var _routeFetchRetried as Boolean = false;
    // Set when _fetchSelectedRoute deferred because a map tile was already in flight - retried from _onTick.
    private var _routeFetchPending as Boolean = false;
    // Departure/arrival airport-info lookups - independent of the route fetch and of each other.
    // AirportClient itself has no in-flight guard (stateless, safe to overlap) or timeout of its own.
    private var _airportFetchHex as String?;
    private var _pendingDepIcao as String?;
    private var _pendingArrIcao as String?;
    private var _airportFetchStartMs as Number?;

    private var _manualFocus as [Float, Float]?;
    private var _dragStartCoords as [Number, Number]?;
    private var _dragLastCoords as [Number, Number]?;
    private var _dragCommitted as Boolean = false;
    private var _touchDownInDetailPanel as Boolean = false;
    private var _lastRadiusPx as Number = 1;
    private var _lastScreenHeight as Number = 1;
    // Timestamp-gated, not a plain flag - a standalone tap may never fire beginDrag on real hardware.
    private var _dragStopAtMs as Number?;
    private const TAP_SUPPRESS_WINDOW_MS = 300;
    // Trailing touch events from opening/closing the full-detail view can bleed into whatever's on top next.
    private var _inputSuppressedUntilMs as Number?;

    private var _pollTimer as Timer.Timer?;
    private var _ticksSincePoll as Number = 0;
    // Held here, not a local - an unreferenced Timer can be garbage-collected before it fires.
    private var _routeRetryTimer as Timer.Timer?;
    // Drives the fetch spinner's orbit animation, without redrawing so often it hurts battery.
    private const ANIM_TICK_MS = 100;
    // batterySaverMode doubles the real tick interval (set once in onShow, Timer intervals can't change while running) - otherwise it only ever scaled the fetch poll interval, not background tick work.
    private var _tickIntervalMs as Number = ANIM_TICK_MS;
    // The screen going dark (wrist down) doesn't hide this view - _onTick keeps polling for nobody unless told.
    private var _displayOff as Boolean = false;

    // Both piggyback on _onTick's existing cadence, not their own Timer - a second resident Timer
    // already crashed this app once with "Too Many Timers Error" (see [[connectiq_gotchas]]).
    private var _zoomChangedAtMs as Number?;
    // Not lower - _onTick's own cadence (ANIM_TICK_MS) is the real floor on how fast this can fire.
    private const ZOOM_DEBOUNCE_MS = ANIM_TICK_MS;
    private var _nextRetryAtMs as Number?;
    private var _retryBackoffMs as Number = INITIAL_RETRY_BACKOFF_MS;
    private const INITIAL_RETRY_BACKOFF_MS = 1000;
    private const MAX_RETRY_BACKOFF_MS = 16000;

    private var _noGpsText as String = "";
    private var _noSignalText as String = "";
    private var _tooBusyText as String = "";
    private var _fetchingText as String = "";
    private var _liveText as String = "";
    private var _mapLoadingText as String = "";
    private var _fontSmall as Graphics.FontType = Graphics.FONT_SMALL;
    private var _fontTiny as Graphics.FontType = Graphics.FONT_XTINY;
    private var _client as AirplanesLiveClient = new AirplanesLiveClient();
    private var _openSky as OpenSkyClient = new OpenSkyClient();
    private var _routeClient as RouteClient = new RouteClient();
    private var _airportClient as AirportClient = new AirportClient();

    private var _mapClient as MapClient = new MapClient(
        method(:_onTileReceive)
    );
    // bitmap, x, y, z, tileSize, topLeftLatLon, bottomRightLatLon - the last two (elements 5/6)
    // are computed once at fetch time, not per-draw - see _onTileReceive.
    typedef MapTile as
        [
            Graphics.BitmapType,
            Number,
            Number,
            Number,
            Number,
            [Float, Float],
            [Float, Float],
        ];
    private var _mapTileCache as Dictionary<String, MapTile> = {};
    // Style/dark combo the cache was fetched under - cache keys don't include style, so a change here must evict it all.
    private var _mapCachedStyleKey as String?;
    private var _mapNeededKeys as Dictionary<String, Boolean> = {};
    // Mirrors _mapNeededKeys with the actual tuples, for the draw pass's pending-tile placeholder.
    private var _mapNeededTiles as Array<[Number, Number, Number, Number]> = [];
    // Previous zoom's tiles, drawn scaled to the new view until superseded by the real tile.
    private var _staleMapTiles as Array<MapTile> = [];
    private var _staleMapTilesSetAtMs as Number?;
    // Hard safety valve, not the primary bound (that's _pruneStaleTilesCoveredBy) - HI tiles
    // weigh 4x a STD by pixel area, so this is the real confirmed-safe ceiling (5 HI tiles) in
    // STD-units. Checked after every prune; if pruning ever falls behind, drop the stale set
    // entirely rather than risk it.
    private const MAP_STALE_HARD_CEILING_STD_UNITS = 20;
    // A repeatedly-failing tile keeps _hasPendingMapBacklog() true forever (retried on its own
    // uncapped backoff) - this bounds how long stale tiles are held regardless of backlog state.
    private const MAP_STALE_MAX_AGE_MS = 30000;

    private var _mapPendingZoomIndex as Number?;
    private var _mapPendingLat as Float?;
    private var _mapPendingLon as Float?;
    private var _mapPendingSinceMs as Number?;
    private const MAP_FETCH_DEBOUNCE_MS = 100;
    private const MAP_DEBOUNCE_RESET_THRESHOLD_KM = 0.05;
    // A followed aircraft's position never holds still long enough to pass the debounce above on its own.
    private var _mapForceRefetch as Boolean = false;

    // Refetch checks compare against this, not the received tiles, to avoid re-requesting a slow fetch.
    private var _mapRequestedZoomIndex as Number?;
    private var _mapRequestedLat as Float?;
    private var _mapRequestedLon as Float?;
    // Same backoff shape as the airplanes.live poll, shared across all tiles since only one
    // request is ever in flight.
    private var _mapNextRetryAtMs as Number?;
    private var _mapRetryBackoffMs as Number = MAP_INITIAL_RETRY_BACKOFF_MS;
    private const MAP_INITIAL_RETRY_BACKOFF_MS = 2000;
    private const MAP_MAX_RETRY_BACKOFF_MS = 32000;

    // Trades a smaller pan buffer for tile count - a bigger margin needs too many tiles for
    // sequential fetching/memory at native (unshifted) zoom.
    private const MAP_OVERSCAN_FACTOR = 1.1;
    private const MAP_REFETCH_MARGIN_FACTOR = 0.75;
    // A 6th concurrently-cached 512x512-class tile reliably fails - stay comfortably under that.
    private const MAP_MAX_TILES_FOR_HI_RES = 5;

    // One bitmap per shape - emergency is a separate fixed-offset badge, not a variant of this bitmap.
    // Loaded lazily via _bitmapForShape (loading all 84 up front in onLayout cost real time on app open).
    private var _iconBitmapCache as Dictionary<String, Graphics.BitmapType> =
        {};

    private const ICON_RESOURCE_IDS as Dictionary<String, ResourceId> =
        ({
            "a10" => Rez.Drawables.AircraftA10,
            "a225" => Rez.Drawables.AircraftA225,
            "a319" => Rez.Drawables.AircraftA319,
            "a320" => Rez.Drawables.AircraftA320,
            "a321" => Rez.Drawables.AircraftA321,
            "a332" => Rez.Drawables.AircraftA332,
            "a359" => Rez.Drawables.AircraftA359,
            "a380" => Rez.Drawables.AircraftA380,
            "a400" => Rez.Drawables.AircraftA400,
            "airliner" => Rez.Drawables.AircraftAirliner,
            "alpha_jet" => Rez.Drawables.AircraftAlphaJet,
            "apache" => Rez.Drawables.AircraftApache,
            "b1b_lancer" => Rez.Drawables.AircraftB1bLancer,
            "b52" => Rez.Drawables.AircraftB52,
            "b707" => Rez.Drawables.AircraftB707,
            "b737" => Rez.Drawables.AircraftB737,
            "b738" => Rez.Drawables.AircraftB738,
            "b739" => Rez.Drawables.AircraftB739,
            "bae_hawk" => Rez.Drawables.AircraftBaeHawk,
            "balloon" => Rez.Drawables.AircraftBalloon,
            "beluga" => Rez.Drawables.AircraftBeluga,
            "blackhawk" => Rez.Drawables.AircraftBlackhawk,
            "blimp" => Rez.Drawables.AircraftBlimp,
            "c130" => Rez.Drawables.AircraftC130,
            "c17" => Rez.Drawables.AircraftC17,
            "c2" => Rez.Drawables.AircraftC2,
            "c5" => Rez.Drawables.AircraftC5,
            "cessna" => Rez.Drawables.AircraftCessna,
            "chinook" => Rez.Drawables.AircraftChinook,
            "cirrus_sr22" => Rez.Drawables.AircraftCirrusSr22,
            "dauphin" => Rez.Drawables.AircraftDauphin,
            "e390" => Rez.Drawables.AircraftE390,
            "e3awacs" => Rez.Drawables.AircraftE3awacs,
            "e737" => Rez.Drawables.AircraftE737,
            "f18" => Rez.Drawables.AircraftF18,
            "f35" => Rez.Drawables.AircraftF35,
            "f5_tiger" => Rez.Drawables.AircraftF5Tiger,
            "gazelle" => Rez.Drawables.AircraftGazelle,
            "glider" => Rez.Drawables.AircraftGlider,
            "ground_emergency" => Rez.Drawables.AircraftGroundEmergency,
            "ground_service" => Rez.Drawables.AircraftGroundService,
            "ground_tower" => Rez.Drawables.AircraftGroundTower,
            "ground_unknown" => Rez.Drawables.AircraftGroundUnknown,
            "gyrocopter" => Rez.Drawables.AircraftGyrocopter,
            "heavy_2e" => Rez.Drawables.AircraftHeavy2e,
            "heavy_4e" => Rez.Drawables.AircraftHeavy4e,
            "helicopter" => Rez.Drawables.AircraftHelicopter,
            "hi_perf" => Rez.Drawables.AircraftHiPerf,
            "hunter" => Rez.Drawables.AircraftHunter,
            "il_62" => Rez.Drawables.AircraftIl62,
            "jet_nonswept" => Rez.Drawables.AircraftJetNonswept,
            "jet_swept" => Rez.Drawables.AircraftJetSwept,
            "l159" => Rez.Drawables.AircraftL159,
            "lancaster" => Rez.Drawables.AircraftLancaster,
            "m326" => Rez.Drawables.AircraftM326,
            "md11" => Rez.Drawables.AircraftMd11,
            "md_a4" => Rez.Drawables.AircraftMdA4,
            "md_f15" => Rez.Drawables.AircraftMdF15,
            "mil24" => Rez.Drawables.AircraftMil24,
            "mirage" => Rez.Drawables.AircraftMirage,
            "miragef1" => Rez.Drawables.AircraftMiragef1,
            "p3_orion" => Rez.Drawables.AircraftP3Orion,
            "p8" => Rez.Drawables.AircraftP8,
            "pa24" => Rez.Drawables.AircraftPa24,
            "para" => Rez.Drawables.AircraftPara,
            "puma" => Rez.Drawables.AircraftPuma,
            "rafale" => Rez.Drawables.AircraftRafale,
            "rutan_veze" => Rez.Drawables.AircraftRutanVeze,
            "s61" => Rez.Drawables.AircraftS61,
            "sb39" => Rez.Drawables.AircraftSb39,
            "strato" => Rez.Drawables.AircraftStrato,
            "super_guppy" => Rez.Drawables.AircraftSuperGuppy,
            "t38" => Rez.Drawables.AircraftT38,
            "tiger" => Rez.Drawables.AircraftTiger,
            "tornado" => Rez.Drawables.AircraftTornado,
            "twin_large" => Rez.Drawables.AircraftTwinLarge,
            "typhoon" => Rez.Drawables.AircraftTyphoon,
            "u2" => Rez.Drawables.AircraftU2,
            "uav" => Rez.Drawables.AircraftUav,
            "unknown" => Rez.Drawables.AircraftUnknown,
            "v22_fast" => Rez.Drawables.AircraftV22Fast,
            "v22_slow" => Rez.Drawables.AircraftV22Slow,
            "verhees" => Rez.Drawables.AircraftVerhees,
            "wb57" => Rez.Drawables.AircraftWb57,
        }) as Dictionary<String, ResourceId>;

    public function initialize() {
        View.initialize();
    }

    public function onLayout(dc as Dc) as Void {
        _noGpsText = WatchUi.loadResource(Rez.Strings.NoGps) as String;
        _noSignalText = WatchUi.loadResource(Rez.Strings.NoSignal) as String;
        _tooBusyText = WatchUi.loadResource(Rez.Strings.TooBusy) as String;
        _fetchingText = WatchUi.loadResource(Rez.Strings.Fetching) as String;
        _liveText = WatchUi.loadResource(Rez.Strings.Fetched) as String;
        _mapLoadingText =
            WatchUi.loadResource(Rez.Strings.MapLoading) as String;
        _fontSmall =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_SMALL) as
            Graphics.FontDefinition;
        _fontTiny =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_TINY) as
            Graphics.FontDefinition;
        var charSize = DrawUtil.measureChar(dc, _fontTiny);
        _charW = charSize[0];
        _charH = charSize[1];
        // Sized to fit the button hints with a visible gap on both sides - see BUTTON_HINT_REACH_PX.
        _edgeMargin = BUTTON_HINT_REACH_PX * 2;
        _gridLabelInset = _charH + _charW;
        _topPanelLineHeight = _charH + 4;
        _detailPanelLineHeight = _charH + 4;
        _labelOverlapMarginPx = _charW / 2;
        _labelLineGapPx = _charH / 8;
        _labelVoffsetBase = _charH.toFloat() * 1.3;
        _chevronMarginPx = _charH + 6;
        _segmentGapPx = _charW;
    }

    // A single recurring Timer, not two - a second one alongside the poll timer hit the "Too Many Timers" limit.
    public function onShow() as Void {
        _tickIntervalMs = Settings.batterySaverMode
            ? ANIM_TICK_MS * 2
            : ANIM_TICK_MS;
        var timer = new Timer.Timer();
        timer.start(method(:_onTick), _tickIntervalMs, true);
        _pollTimer = timer;
        _ticksSincePoll = 0;

        if (!_hasFix) {
            _tryLastKnownPosition();
        }
        _fetchNow();
    }

    // A cold GPS fix can take 30s+, longer than the screen stays on - seed from the system's cached
    // last-known fix instead; onPosition() overwrites it once a live fix arrives.
    private function _tryLastKnownPosition() as Void {
        var loc = Activity.getActivityInfo().currentLocation;
        if (loc != null) {
            var deg = (loc as Position.Location).toDegrees();
            var lat = deg[0].toFloat();
            var lon = deg[1].toFloat();
            // A few devices are known to report (0,0) or (180,180) instead of null when there's no cached fix.
            if (
                !(lat == 0.0 and lon == 0.0 or (lat == 180.0 and lon == 180.0))
            ) {
                _centerLat = lat;
                _centerLon = lon;
                _hasFix = true;
                return;
            }
        }

        // currentLocation only reflects the last time something actually used GPS, and goes stale/null
        // after roughly an hour of no GPS use - the watch never polls GPS just from being worn. Fall
        // back to wherever this app last had a real fix, persisted in onHide.
        var storedLat = Storage.getValue(STORAGE_KEY_LAT);
        var storedLon = Storage.getValue(STORAGE_KEY_LON);
        var storedTs = Storage.getValue(STORAGE_KEY_TS);
        if (
            storedLat != null and
            storedLon != null and
            storedTs != null and
            Time.now().value() - (storedTs as Number) <=
                MAX_STORED_POSITION_AGE_SEC
        ) {
            _centerLat = storedLat as Float;
            _centerLon = storedLon as Float;
            _hasFix = true;
        }
    }

    public function onHide() as Void {
        if (_pollTimer != null) {
            (_pollTimer as Timer.Timer).stop();
            _pollTimer = null;
        }
    }

    // Called from FlightradarApp.onStop (real app exit), not onHide - onHide also fires every time a
    // menu/detail view is pushed on top, which would write far more often than needed.
    public function persistLastKnownPosition() as Void {
        // Gate on a real fix, not _hasFix - a stale fallback seed could otherwise re-stamp as fresh forever.
        if (_liveFixAtSec != null) {
            Storage.setValue(STORAGE_KEY_LAT, _centerLat);
            Storage.setValue(STORAGE_KEY_LON, _centerLon);
            Storage.setValue(STORAGE_KEY_TS, _liveFixAtSec);
        }
    }

    public function onDisplayModeChanged(mode as System.DisplayMode) as Void {
        var wasOff = _displayOff;
        _displayOff = mode == System.DISPLAY_MODE_OFF;
        if (wasOff && !_displayOff) {
            _ticksSincePoll = 0;
            _fetchNow();
        }
    }

    private function _isTimedOut(
        startedAt as Number?,
        now as Number
    ) as Boolean {
        return startedAt != null and now - startedAt > FETCH_TIMEOUT_MS;
    }

    // Guards against a response landing after the selection changed mid-fetch.
    private function _hexStillSelected(fetchedHex as String?) as Boolean {
        return (
            fetchedHex != null &&
            _selectedHex != null &&
            (fetchedHex as String).equals(_selectedHex as String)
        );
    }

    public function _onTick() as Void {
        if (_displayOff) {
            return;
        }

        var now = System.getTimer();

        // The only safe call site for this - see resume()'s own comment for why; the timeout
        // checks below share the same reentrancy reason for living only here too.
        _mapClient.tick();

        // Retries here too, not just from their own result handlers - a pending fetch deferred because MapClient was busy has no other event to wake it back up once that clears.
        if (_refetchPending) {
            _fetchNow();
        }
        if (_trackFetchPending) {
            _fetchSelectedTrack();
        }
        if (_routeFetchPending) {
            _fetchSelectedRoute();
        }

        // Each treated as a real failure via its own existing recovery path, not cancelled outright
        // (cancelAllRequests() crashed on real hardware) - a hung callback would otherwise leave
        // that request (and, via MapClient's own busy-check, the aircraft poll too) stuck forever.
        if (_fetchInFlight and _isTimedOut(_fetchStartMs, now)) {
            _onFetchResult([], false, false);
        }
        if (_trackFetchInFlight and _isTimedOut(_trackFetchStartMs, now)) {
            _onTrackResult(_trackFetchHex as String, [], false);
        }
        if (_routeFetchInFlight and _isTimedOut(_routeFetchStartMs, now)) {
            _onRouteResult(_routeFetchHex as String, null, null, false);
        }
        // AirportClient itself has no timeout - synthesize the same "no info" fallback its own
        // failure path already produces, reusing _onAirportInfoResult's existing icao-match/clear logic.
        if (
            _pendingDepIcao != null or
            (_pendingArrIcao != null and _isTimedOut(_airportFetchStartMs, now))
        ) {
            if (_pendingDepIcao != null) {
                _onAirportInfoResult(_pendingDepIcao as String, null);
            }
            if (_pendingArrIcao != null) {
                _onAirportInfoResult(_pendingArrIcao as String, null);
            }
        }

        // Debounced: a burst of zoom taps only fetches once, shortly after the last one.
        var changedAt = _zoomChangedAtMs;
        if (
            changedAt != null &&
            now - (changedAt as Number) >= ZOOM_DEBOUNCE_MS
        ) {
            _zoomChangedAtMs = null;
            _fetchNow();
        }

        var hasMapBacklog = _hasPendingMapBacklog();
        if (
            _staleMapTiles.size() > 0 and
            (!hasMapBacklog or
                now - (_staleMapTilesSetAtMs as Number) > MAP_STALE_MAX_AGE_MS)
        ) {
            _staleMapTiles = [];
            _staleMapTilesSetAtMs = null;
        }

        var nextRetry = _nextRetryAtMs;
        if (nextRetry != null) {
            // A failure (e.g. rate-limited) retries on its own backoff, not the normal poll cadence,
            // so it recovers faster than a full poll period and without immediately re-triggering the limit.
            if (now >= (nextRetry as Number)) {
                _nextRetryAtMs = null;
                _fetchNow();
            }
        } else {
            _ticksSincePoll += 1;
            // Normal per-zoom cadence even during a map backlog - polling faster there just steals
            // more of the shared channel from the tiles actually trying to catch up.
            var pollMs = POLL_MS_BY_ZOOM[Settings.zoomIndex];
            if (Settings.batterySaverMode) {
                pollMs *= BATTERY_SAVER_MULTIPLIER;
            }
            if (_ticksSincePoll * _tickIntervalMs >= pollMs) {
                _ticksSincePoll = 0;
                _fetchNow();
            }
        }

        // Also runs here, not just from onUpdate - nothing else guarantees the debounce gets rechecked.
        // _lastScreenHeight > 1 skips its pre-first-draw default, avoiding a bogus 1x1-screen computation.
        if (
            Settings.showBackgroundMap &&
            _hasFix &&
            _centerLat != null &&
            _centerLon != null &&
            _lastScreenHeight > 1
        ) {
            var focus = _focusPoint();
            var screenSize = _lastScreenHeight;
            if (
                _maybeFetchBackgroundMap(
                    focus[0],
                    focus[1],
                    _lastRadiusPx,
                    Settings.zoomRadiusKm(),
                    screenSize / 2,
                    screenSize / 2,
                    screenSize,
                    screenSize
                )
            ) {
                WatchUi.requestUpdate();
            }
        }

        if (_fetchInFlight) {
            WatchUi.requestUpdate();
        }
    }

    public function onPosition(info as Position.Info) as Void {
        var pos = info.position;
        if (pos == null) {
            // A fix already established can be lost again (e.g. indoors) - don't keep rendering on stale coordinates.
            _hasFix = false;
            WatchUi.requestUpdate();
            return;
        }

        var deg = pos.toDegrees();
        _centerLat = deg[0].toFloat();
        _centerLon = deg[1].toFloat();
        _liveFixAtSec = Time.now().value();

        var firstFix = !_hasFix;
        _hasFix = true;
        if (firstFix) {
            _fetchNow();
        }

        WatchUi.requestUpdate();
    }

    public function zoomIn() as Void {
        Settings.zoomIn();
        _scheduleDebouncedFetch();
        WatchUi.requestUpdate();
    }

    public function zoomOut() as Void {
        Settings.zoomOut();
        _scheduleDebouncedFetch();
        WatchUi.requestUpdate();
    }

    // A fresh zoom action supersedes any pending failure retry for the old level.
    private function _scheduleDebouncedFetch() as Void {
        _zoomChangedAtMs = System.getTimer();
        _nextRetryAtMs = null;
        _retryBackoffMs = INITIAL_RETRY_BACKOFF_MS;
        _viewHasFreshData = false;
    }

    // False when nothing's left to clear - lets the caller fall through to exit.
    public function recenter() as Boolean {
        if (_manualFocus != null) {
            _manualFocus = null;
            _viewHasFreshData = false;
            _fetchNow();
            WatchUi.requestUpdate();
            return true;
        }
        if (_selectedHex != null) {
            deselectAircraft();
            return true;
        }
        return false;
    }

    public function beginDrag(x as Number, y as Number) as Void {
        // Never cleared by endDrag - trySwipeOpenDetail reads this later since SwipeEvent has no coordinates.
        _touchDownInDetailPanel = _isInDetailPanelZone(x, y);
        if (
            _touchDownInDetailPanel or
            !_hasFix or
            _centerLat == null or
            _centerLon == null
        ) {
            return;
        }
        _dragStartCoords = [x, y];
        _dragLastCoords = [x, y];
        _dragCommitted = false;
    }

    // Panning never clears the current selection, only detaches the camera from following it.
    public function continueDrag(x as Number, y as Number) as Void {
        var start = _dragStartCoords;
        var last = _dragLastCoords;
        if (start == null or last == null) {
            return;
        }

        if (!_dragCommitted) {
            var totalDx = x - (start as [Number, Number])[0];
            var totalDy = y - (start as [Number, Number])[1];
            if (
                totalDx * totalDx + totalDy * totalDy <
                DRAG_THRESHOLD_PX * DRAG_THRESHOLD_PX
            ) {
                _dragLastCoords = [x, y];
                return;
            }
            _manualFocus = _focusPoint();
            _dragCommitted = true;
        }

        _applyDragDelta(x, y);
        WatchUi.requestUpdate();
    }

    // Shared by continueDrag and endDrag.
    private function _applyDragDelta(x as Number, y as Number) as Void {
        var last = _dragLastCoords;
        if (last == null) {
            return;
        }
        var dxPx = x - (last as [Number, Number])[0];
        var dyPx = y - (last as [Number, Number])[1];
        _dragLastCoords = [x, y];

        var focus = _manualFocus;
        if (focus == null) {
            return;
        }
        var delta = Projection.screenDeltaToLatLon(
            dxPx,
            dyPx,
            (focus as [Float, Float])[0],
            _lastRadiusPx,
            Settings.zoomRadiusKm()
        );
        _manualFocus = [
            (focus as [Float, Float])[0] + delta[0],
            (focus as [Float, Float])[1] + delta[1],
        ];
    }

    public function endDrag(x as Number, y as Number) as Void {
        var wasCommitted = _dragCommitted;
        if (wasCommitted) {
            _applyDragDelta(x, y);
        }
        _dragStartCoords = null;
        _dragLastCoords = null;
        _dragCommitted = false;
        if (wasCommitted) {
            _dragStopAtMs = System.getTimer();
            _viewHasFreshData = false;
            _fetchNow();
            WatchUi.requestUpdate();
        }
    }

    public function consumeTapSuppression() as Boolean {
        var stoppedAt = _dragStopAtMs;
        if (stoppedAt == null) {
            return false;
        }
        _dragStopAtMs = null;
        return (
            System.getTimer() - (stoppedAt as Number) < TAP_SUPPRESS_WINDOW_MS
        );
    }

    // A physical drag gesture can interleave a stray onTap mid-gesture, not just right after it ends.
    public function isDragActive() as Boolean {
        return _dragStartCoords != null;
    }

    public function suppressInputBriefly() as Void {
        _inputSuppressedUntilMs = System.getTimer() + TAP_SUPPRESS_WINDOW_MS;
    }

    public function isInputSuppressed() as Boolean {
        var until = _inputSuppressedUntilMs;
        return until != null and System.getTimer() < (until as Number);
    }

    public function hitTestAircraft(x as Number, y as Number) as String? {
        // _lastDrawnPositions can still hold entries from before a fix was lost - onUpdate stops
        // redrawing them (falls back to "No GPS"), but a tap could still hit the stale coordinates.
        if (!_hasFix) {
            return null;
        }

        var best = null as String?;
        var bestDistSq = HIT_RADIUS_PX * HIT_RADIUS_PX;

        for (var i = 0; i < _lastDrawnPositions.size(); i++) {
            var entry = _lastDrawnPositions[i];
            var dx = x - (entry[1] as Number);
            var dy = y - (entry[2] as Number);
            var distSq = dx * dx + dy * dy;
            if (distSq <= bestDistSq) {
                bestDistSq = distSq;
                best = entry[0] as String;
            }
        }

        return best;
    }

    public function selectAircraft(hex as String) as Void {
        if (_selectedHex != null && (_selectedHex as String).equals(hex)) {
            return;
        }
        _selectedHex = hex;
        _selectedTrack = [];
        _trackHasHistory = false;
        _selectedMissCount = 0;
        _trackFetchRetried = false;
        _routeFetchRetried = false;
        _manualFocus = null;
        var ac = _aircraftByHex[hex];
        _selectedLastPos = ac != null ? [ac.lat, ac.lon] : null;
        _fetchSelectedTrack();
        _mapForceRefetch = true;
        WatchUi.requestUpdate();
    }

    public function deselectAircraft() as Void {
        _selectedHex = null;
        _selectedTrack = [];
        _selectedMissCount = 0;
        _selectedLastPos = null;
        _mapForceRefetch = true;
        WatchUi.requestUpdate();
    }

    // Freezes the camera at its current position first, so tapping empty space doesn't also recenter to self.
    public function deselectAircraftKeepView() as Void {
        if (_selectedHex != null) {
            _manualFocus = _focusPoint();
        }
        deselectAircraft();
    }

    private function _isInDetailPanelZone(x as Number, y as Number) as Boolean {
        var ac = _selectedAircraft();
        if (ac == null) {
            return false;
        }
        var panelH = _detailPanelHeight(ac as Aircraft);
        return (
            panelH != 0 &&
            y >= _lastScreenHeight - panelH - CHEVRON_TAP_MARGIN_PX
        );
    }

    // True (and opens full detail) for a tap anywhere on the compact panel, chevron margin included.
    public function tryOpenDetailPanel(x as Number, y as Number) as Boolean {
        if (!_isInDetailPanelZone(x, y)) {
            return false;
        }
        openFullDetail();
        return true;
    }

    // SwipeEvent has no coordinates, so this reads where the gesture's touch-down landed instead - see beginDrag.
    public function trySwipeOpenDetail() as Boolean {
        if (!_touchDownInDetailPanel) {
            return false;
        }
        openFullDetail();
        return true;
    }

    public function openFullDetail() as Void {
        var ac = _selectedAircraft() as Aircraft?;
        if (ac == null) {
            return;
        }
        var header =
            (ac as Aircraft).flight != null &&
            ((ac as Aircraft).flight as String).length() > 0
                ? (ac as Aircraft).flight as String
                : (ac as Aircraft).hex;
        var built = _buildFullDetailRows(ac as Aircraft);
        // Reuses the radar's own ring/panel geometry so the separators line up with the radar underneath.
        var ringCx = _lastScreenHeight / 2;
        var view = new AircraftDetailView(
            header,
            _colorForAircraft(ac as Aircraft),
            built[0] as Array<Array<[String, Array<DrawUtil.ValueRun>]> >,
            built[1] as Number,
            built[2] as Number,
            built[3] as Array<Boolean>,
            ringCx,
            ringCx,
            _lastRadiusPx,
            _topPanelHeight(),
            _topPanelHeight() // bottom band matches the header's own height, not the (variable) compact panel height
        );
        _detailView = view;
        WatchUi.pushView(
            view,
            new AircraftDetailDelegate(view, self),
            WatchUi.SLIDE_UP
        );
        _fetchSelectedRoute();
        // pushView triggers onHide, which stops _pollTimer/_onTick - the only thing that would
        // otherwise retry a route fetch deferred here because a map tile was in flight. One bounded
        // one-shot retry (not a persistent timer) covers the common case without depending on _onTick.
        if (_routeFetchPending) {
            if (_routeRetryTimer != null) {
                (_routeRetryTimer as Timer.Timer).stop();
            }
            _routeRetryTimer = new Timer.Timer();
            (_routeRetryTimer as Timer.Timer).start(
                method(:_fetchSelectedRoute),
                ROUTE_RETRY_AFTER_HIDE_MS,
                false
            );
        }
    }

    public function _fetchSelectedRoute() as Void {
        var hex = _selectedHex;
        if (hex == null) {
            _routeFetchPending = false;
            _mapClient.resumeFor(:route);
            return;
        }
        if (_routeFetchInFlight) {
            return;
        }
        if (_pauseAndCheckBusy(:route)) {
            _routeFetchPending = true;
            return;
        }
        _routeFetchPending = false;
        _routeFetchInFlight = true;
        _routeFetchStartMs = System.getTimer();
        _routeFetchHex = hex;
        var ac = _selectedAircraft();
        var callsign = ac != null ? (ac as Aircraft).flight : null;
        if (callsign == null) {
            // No callsign to look up by - same "no route found" outcome as a 404.
            _onRouteResult(hex as String, null, null, true);
            return;
        }
        _routeClient.fetchRoute(
            hex as String,
            callsign as String,
            method(:_onRouteResult)
        );
    }

    public function _onRouteResult(
        hex as String,
        dep as String?,
        arr as String?,
        ok as Boolean
    ) as Void {
        _routeFetchInFlight = false;
        _mapClient.resumeFor(:route);

        var view = _detailView;
        if (view == null) {
            return;
        }
        var stillRelevant = _hexStillSelected(hex);
        if (!stillRelevant) {
            // Reopened for a different aircraft mid-fetch - retry for what's actually showing.
            _fetchSelectedRoute();
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
                    DrawUtil.plainRuns("Unknown", COLOR_ROUTE_DIM)
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
                    DrawUtil.plainRuns("Unknown", COLOR_ROUTE_DIM)
                );
            }
            return;
        }

        if (!_routeFetchRetried) {
            _routeFetchRetried = true;
            _fetchSelectedRoute();
            return;
        }
        (view as AircraftDetailView).setDepartureText(
            DrawUtil.plainRuns("Unavailable", COLOR_ROUTE_DIM)
        );
        (view as AircraftDetailView).setArrivalText(
            DrawUtil.plainRuns("Unavailable", COLOR_ROUTE_DIM)
        );
    }

    // Checks both pending slots - icao alone doesn't say dep vs arr (touch-and-go can have dep==arr).
    public function _onAirportInfoResult(
        icao as String,
        text as String?
    ) as Void {
        var view = _detailView;
        if (view == null) {
            return;
        }
        var stillRelevant = _hexStillSelected(_airportFetchHex);
        if (!stillRelevant) {
            return;
        }

        // ICAO itself is still a resolved value even if the detail lookup failed.
        var segments =
            text != null
                ? DrawUtil.plainRuns(text as String, COLOR_SUCCESS)
                : [
                      DrawUtil.plainRun(icao, COLOR_SUCCESS),
                      DrawUtil.plainRun(" (no info)", COLOR_ROUTE_DIM),
                  ] as Array<DrawUtil.ValueRun>;
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

    // Called from AircraftDetailDelegate once the pushed view is popped, so a late route result has nothing left to update.
    public function onDetailClosed() as Void {
        _detailView = null;
        // Otherwise a pending airport lookup never clears, and _onTick's timeout re-fires it forever.
        _pendingDepIcao = null;
        _pendingArrIcao = null;
        _airportFetchStartMs = null;
        suppressInputBriefly();
    }

    private function _fetchSelectedTrack() as Void {
        var hex = _selectedHex;
        if (hex == null) {
            _trackFetchPending = false;
            _mapClient.resumeFor(:track);
            return;
        }
        if (_trackFetchInFlight) {
            return;
        }
        if (_pauseAndCheckBusy(:track)) {
            _trackFetchPending = true;
            return;
        }
        _trackFetchPending = false;
        _trackFetchInFlight = true;
        _detailLinesCacheHex = null;
        _trackFetchStartMs = System.getTimer();
        _trackFetchHex = hex;
        _openSky.fetchTrack(hex as String, method(:_onTrackResult));
    }

    public function _onTrackResult(
        hex as String,
        points as Array<[Float, Float, Number, Boolean]>,
        ok as Boolean
    ) as Void {
        _trackFetchInFlight = false;
        _detailLinesCacheHex = null;
        _mapClient.resumeFor(:track);

        var stillSelected = _hexStillSelected(hex);

        if (stillSelected && ok) {
            _trackFetchRetried = false;
            _selectedTrack = points;
            _trackHasHistory = points.size() > 0;
            var ac = _selectedAircraft();
            if (ac != null) {
                _appendLiveTrackPoint(ac as Aircraft);
            }
        }

        // Genuine failure, not a stale selection - one retry so a single network blip doesn't stick forever.
        if (stillSelected && !ok && !_trackFetchRetried) {
            _trackFetchRetried = true;
            _fetchSelectedTrack();
        }

        if (!stillSelected) {
            // Selection changed mid-fetch - this result is stale, try the current selection instead.
            _fetchSelectedTrack();
        }

        WatchUi.requestUpdate();
    }

    // Paused before the busy check, not after - so MapClient can't auto-advance to a fresh tile in
    // the gap and starve the caller behind an entire new batch instead of just the one in-flight tile.
    private function _pauseAndCheckBusy(owner as Symbol) as Boolean {
        _mapClient.pauseFor(owner);
        return _mapClient.isBusy();
    }

    private function _fetchNow() as Void {
        if (_fetchInFlight) {
            _refetchPending = true;
            return;
        }
        if (!_hasFix or _centerLat == null or _centerLon == null) {
            _mapClient.resumeFor(:poll);
            return;
        }
        if (_pauseAndCheckBusy(:poll)) {
            _refetchPending = true;
            return;
        }
        _refetchPending = false;
        var focus = _focusPoint();
        _fetchInFlight = true;
        _fetchStartMs = System.getTimer();
        _client.fetch(
            focus[0],
            focus[1],
            Settings.zoomRadiusKm(),
            method(:_onFetchResult)
        );
    }

    public function _onFetchResult(
        aircraft as Array<Aircraft>,
        ok as Boolean,
        tooMuchData as Boolean
    ) as Void {
        _fetchInFlight = false;
        _lastFetchOk = ok;
        _lastFetchTooMuchData = tooMuchData;
        _mapClient.resumeFor(:poll);

        if (ok) {
            _ticksSincePoll = 0;
            _nextRetryAtMs = null;
            _retryBackoffMs = INITIAL_RETRY_BACKOFF_MS;
            _viewHasFreshData = true;

            var byHex = ({}) as Dictionary<String, Aircraft>;
            for (var i = 0; i < aircraft.size(); i++) {
                byHex[aircraft[i].hex] = aircraft[i];
            }
            _aircraft = aircraft;
            _aircraftByHex = byHex;
            // Category/shape/scale can only change when the underlying aircraft data does, not every redraw.
            _classifyCache = {};
            _detailLinesCacheHex = null;
            _labelLinesCache = {};

            var selected = _selectedHex;
            if (selected != null) {
                var selectedAc = byHex[selected];
                if (selectedAc == null) {
                    _selectedMissCount += 1;
                    if (_selectedMissCount >= MAX_SELECTED_MISSES) {
                        // _focusPoint() would fall through to the user's position here - freeze the last fix instead.
                        if (_manualFocus == null) {
                            _manualFocus = _selectedLastPos;
                        }
                        deselectAircraft();
                    }
                } else {
                    _selectedMissCount = 0;
                    _selectedLastPos = [
                        (selectedAc as Aircraft).lat,
                        (selectedAc as Aircraft).lon,
                    ];
                    _appendLiveTrackPoint(selectedAc as Aircraft);
                }
            }
        } else {
            _nextRetryAtMs = System.getTimer() + _retryBackoffMs;
            _retryBackoffMs *= 2;
            if (_retryBackoffMs > MAX_RETRY_BACKOFF_MS) {
                _retryBackoffMs = MAX_RETRY_BACKOFF_MS;
            }
        }

        // Left for the next _onTick to pick up (it checks _refetchPending too), rather than
        // retrying synchronously here - resume() above needs a real tick to pass before _fetchNow()
        // pauses MapClient again, or a queued tile never gets a turn to dispatch in between.
        if (_refetchPending) {
            _ticksSincePoll = 0;
        }

        WatchUi.requestUpdate();
    }

    private function _appendLiveTrackPoint(ac as Aircraft) as Void {
        _selectedTrack.add([
            ac.lat,
            ac.lon,
            ac.altBaro != null ? ac.altBaro as Number : 0,
            ac.onGround,
        ]);
        if (_selectedTrack.size() > MAX_SELECTED_TRACK_POINTS) {
            _selectedTrack = _selectedTrack.slice(
                _selectedTrack.size() - MAX_SELECTED_TRACK_POINTS,
                null
            );
        }
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        var radiusPx = (w < h ? w : h) / 2 - _edgeMargin;
        var radiusKm = Settings.zoomRadiusKm();
        _lastRadiusPx = radiusPx;
        _lastScreenHeight = h;
        var topLines = _topPanelLines();
        var topPanelH = _topPanelHeightFor(topLines);

        if (!_hasFix or _centerLat == null or _centerLon == null) {
            dc.setColor(COLORS[0], Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                cy,
                _fontSmall,
                _noGpsText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        var focus = _focusPoint();
        var focusLat = focus[0];
        var focusLon = focus[1];

        var selected = _selectedAircraft();
        var detailLines =
            selected != null
                ? _buildDetailLinesCached(selected as Aircraft)
                : [] as Array<Array<DrawUtil.ValueRun> >;
        var bottomPanelH = _detailPanelHeightFor(detailLines);

        if (Settings.showBackgroundMap) {
            var styleKey =
                Settings.mapStyle + (Settings.mapDarkMode ? "d" : "l");
            var cachedStyleKey = _mapCachedStyleKey;
            if (
                cachedStyleKey != null and
                !(cachedStyleKey as String).equals(styleKey)
            ) {
                _resetMapTileState();
            }
            _mapCachedStyleKey = styleKey;
            _maybeFetchBackgroundMap(
                focusLat,
                focusLon,
                radiusPx,
                radiusKm,
                cx,
                cy,
                w,
                h
            );
            _drawBackgroundMap(
                dc,
                cx,
                cy,
                radiusPx,
                radiusKm,
                focusLat,
                focusLon
            );
        } else {
            // Always pruned, even with an empty cache below - otherwise a still-pending tile leaves _hasPendingMapBacklog() true forever, pinning the poll to its fastest tier with the map off.
            _mapClient.pruneQueue(({}) as Dictionary<String, Boolean>);
            if (
                _mapTileCache.size() > 0 or
                _staleMapTiles.size() > 0 or
                _mapNeededTiles.size() > 0
            ) {
                _resetMapTileState();
            }
        }

        if (Settings.showGridLines) {
            _drawLatLonGrid(
                dc,
                focusLat,
                focusLon,
                cx,
                cy,
                radiusPx,
                radiusKm,
                topPanelH,
                h - bottomPanelH
            );
        }
        _drawChrome(dc, cx, cy, radiusPx, radiusKm, topPanelH);
        // Drawn before aircraft, not after - the user's own marker should never sit on top of a craft icon.
        _drawUserMarker(
            dc,
            focusLat,
            focusLon,
            cx,
            cy,
            radiusPx,
            radiusKm,
            topPanelH,
            h - bottomPanelH
        );
        _drawAircraft(dc, focusLat, focusLon, cx, cy, radiusPx, radiusKm);

        if (selected != null) {
            _drawDetailPanel(dc, cx, cy, h, radiusPx, detailLines);
        }

        _drawTopPanel(dc, cx, cy, radiusPx, topLines);

        if (Settings.showButtonHints) {
            _drawButtonHints(dc, cx, cy, radiusPx);
        }
    }

    private function _focusPoint() as [Float, Float] {
        var manual = _manualFocus;
        if (manual != null) {
            return manual as [Float, Float];
        }
        if (_selectedHex != null) {
            var selected = _selectedAircraft();
            if (selected != null) {
                return [(selected as Aircraft).lat, (selected as Aircraft).lon];
            }
            // Missing from just this one poll (a normal gap, tolerated up to MAX_SELECTED_MISSES) - hold the
            // last known position instead of falling through to the user's own, which read as a random recenter.
            var lastPos = _selectedLastPos;
            if (lastPos != null) {
                return lastPos as [Float, Float];
            }
        }
        return [_centerLat as Float, _centerLon as Float];
    }

    private function _selectedAircraft() as Aircraft? {
        var hex = _selectedHex;
        if (hex == null) {
            return null;
        }
        return _aircraftByHex[hex as String];
    }

    // True only when it evicted/dispatched something - tells a timer-driven caller to redraw.
    // Releases graphics-pool memory immediately - this feature already caused one real OOM crash.
    private function _resetMapTileState() as Void {
        _mapTileCache = {};
        _staleMapTiles = [];
        _staleMapTilesSetAtMs = null;
        _mapNeededKeys = {};
        _mapNeededTiles = [];
        // Also clears the last-requested view - otherwise re-enabling without movement never refetches.
        _mapRequestedLat = null;
    }

    private function _maybeFetchBackgroundMap(
        focusLat as Float,
        focusLon as Float,
        radiusPx as Number,
        radiusKm as Float,
        cx as Number,
        cy as Number,
        screenW as Number,
        screenH as Number
    ) as Boolean {
        // Fetches never fire mid-drag anyway, so skip the trig work every drag frame.
        if (isDragActive()) {
            return false;
        }

        var zoomIndex = Settings.zoomIndex;
        var now = System.getTimer();
        if (_mapForceRefetch) {
            _mapForceRefetch = false;
            _mapPendingZoomIndex = zoomIndex;
            _mapPendingLat = focusLat;
            _mapPendingLon = focusLon;
            _mapPendingSinceMs = now - MAP_FETCH_DEBOUNCE_MS;
        }
        var pendingLat = _mapPendingLat;
        var stillSameTarget =
            _mapPendingZoomIndex == zoomIndex and
            pendingLat != null and
            Projection.distanceKm(
                pendingLat as Float,
                _mapPendingLon as Float,
                focusLat,
                focusLon
            ) <= MAP_DEBOUNCE_RESET_THRESHOLD_KM;

        if (!stillSameTarget or _mapPendingSinceMs == null) {
            _mapPendingZoomIndex = zoomIndex;
            _mapPendingLat = focusLat;
            _mapPendingLon = focusLon;
            _mapPendingSinceMs = now;
            return false;
        }
        if (now - (_mapPendingSinceMs as Number) < MAP_FETCH_DEBOUNCE_MS) {
            return false;
        }

        var nextRetryAt = _mapNextRetryAtMs;
        if (nextRetryAt != null and now < (nextRetryAt as Number)) {
            return false;
        }

        var screenHalfPx = radiusPx + _edgeMargin;
        var overscanMarginKm =
            (screenHalfPx * (MAP_OVERSCAN_FACTOR - 1.0) * radiusKm) / radiusPx;

        var requestedLat = _mapRequestedLat;
        var needsRefetch =
            _mapRequestedZoomIndex != zoomIndex or
            requestedLat == null or
            Projection.distanceKm(
                requestedLat as Float,
                _mapRequestedLon as Float,
                focusLat,
                focusLon
            ) >
                overscanMarginKm * MAP_REFETCH_MARGIN_FACTOR;
        if (!needsRefetch) {
            return false;
        }

        var idealZoom = Projection.webMercatorZoom(
            focusLat,
            radiusKm,
            radiusPx
        );
        // Native zoom, not shifted coarser - tile count is controlled via MAP_OVERSCAN_FACTOR instead.
        var tileZ = Math.round(idealZoom).toNumber();
        var mapHalfPx = screenHalfPx * MAP_OVERSCAN_FACTOR;
        // Args are negated from each corner's name - this returns how far the focus must shift
        // for content to move by (dx,dy), the inverse of "point at screen offset (dx,dy)".
        var cornerA = Projection.screenDeltaToLatLon(
            mapHalfPx.toNumber(),
            mapHalfPx.toNumber(),
            focusLat,
            radiusPx,
            radiusKm
        );
        var cornerB = Projection.screenDeltaToLatLon(
            -mapHalfPx.toNumber(),
            -mapHalfPx.toNumber(),
            focusLat,
            radiusPx,
            radiusKm
        );
        var tileA = Projection.latLonToTile(
            focusLat + (cornerA[0] as Float),
            focusLon + (cornerA[1] as Float),
            tileZ
        );
        var tileB = Projection.latLonToTile(
            focusLat + (cornerB[0] as Float),
            focusLon + (cornerB[1] as Float),
            tileZ
        );
        var minTileX = tileA[0] < tileB[0] ? tileA[0] : tileB[0];
        var maxTileX = tileA[0] > tileB[0] ? tileA[0] : tileB[0];
        var minTileY = tileA[1] < tileB[1] ? tileA[1] : tileB[1];
        var maxTileY = tileA[1] > tileB[1] ? tileA[1] : tileB[1];

        var tileCount = (maxTileX - minTileX + 1) * (maxTileY - minTileY + 1);
        var tileSize =
            tileCount <= MAP_MAX_TILES_FOR_HI_RES
                ? _mapClient.TILE_SIZE_HI
                : _mapClient.TILE_SIZE_STD;

        var centerTile = Projection.latLonToTile(focusLat, focusLon, tileZ);
        var neededKeys = ({}) as Dictionary<String, Boolean>;
        var neededList = [] as Array<[Number, Number, Number, Number]>;
        for (var tx = minTileX; tx <= maxTileX; tx++) {
            for (var ty = minTileY; ty <= maxTileY; ty++) {
                neededKeys[_mapClient.tileKeyFor(tileZ, tx, ty, tileSize)] =
                    true;
                neededList.add([tileZ, tx, ty, tileSize]);
            }
        }
        neededList.sort(
            new TileVisibilityComparator(
                centerTile[0],
                centerTile[1],
                tileZ,
                focusLat,
                focusLon,
                cx,
                cy,
                radiusPx,
                radiusKm,
                screenW,
                screenH
            )
        );

        // Only a real zoom change benefits - panning already keeps most tiles covered by the cache.
        // Safe to keep the old set resident: _pruneStaleTilesCoveredBy evicts each stale tile as its area is replaced, so old/new never stay fully resident together.
        if (
            _mapRequestedZoomIndex != null and
            _mapRequestedZoomIndex != zoomIndex and
            _mapTileCache.size() > 0
        ) {
            _staleMapTiles = _mapTileCache.values();
            _staleMapTilesSetAtMs = now;
        }

        _mapRequestedZoomIndex = zoomIndex;
        _mapRequestedLat = focusLat;
        _mapRequestedLon = focusLon;
        _mapNeededKeys = neededKeys;
        _mapNeededTiles = neededList;

        var cacheKeys = _mapTileCache.keys();
        for (var i = 0; i < cacheKeys.size(); i++) {
            var key = cacheKeys[i] as String;
            if (!neededKeys.hasKey(key)) {
                _mapTileCache.remove(key);
            }
        }
        _mapClient.pruneQueue(neededKeys);

        for (var i = 0; i < neededList.size(); i++) {
            var t = neededList[i];
            var key = _mapClient.tileKeyFor(
                t[0] as Number,
                t[1] as Number,
                t[2] as Number,
                t[3] as Number
            );
            if (!_mapTileCache.hasKey(key)) {
                _mapClient.requestTile(
                    t[0] as Number,
                    t[1] as Number,
                    t[2] as Number,
                    t[3] as Number
                );
            }
        }
        return true;
    }

    private function _hasPendingMapBacklog() as Boolean {
        for (var i = 0; i < _mapNeededTiles.size(); i++) {
            var t = _mapNeededTiles[i];
            var key = _mapClient.tileKeyFor(
                t[0] as Number,
                t[1] as Number,
                t[2] as Number,
                t[3] as Number
            );
            if (!_mapTileCache.hasKey(key)) {
                return true;
            }
        }
        return false;
    }

    public function _onTileReceive(
        z as Number,
        x as Number,
        y as Number,
        tileSize as Number,
        bitmap as MapClient.MapBitmap?
    ) as Void {
        if (bitmap == null) {
            _mapScheduleRetry();
            return;
        }

        // Must resolve via get() - an unresolved BitmapReference isn't a strong reference and can be reclaimed.
        var resolved;
        if (bitmap instanceof Graphics.BitmapReference) {
            try {
                resolved = bitmap.get() as Graphics.BitmapType?;
            } catch (ex instanceof Lang.Exception) {
                resolved = null;
            }
        } else {
            resolved = bitmap as Graphics.BitmapType;
        }
        if (resolved == null) {
            _mapScheduleRetry();
            return;
        }
        _mapNextRetryAtMs = null;
        _mapRetryBackoffMs = MAP_INITIAL_RETRY_BACKOFF_MS;

        var key = _mapClient.tileKeyFor(z, x, y, tileSize);
        // Discarded if panned/zoomed away mid-flight, or the feature got toggled off.
        if (!_mapNeededKeys.hasKey(key) or !Settings.showBackgroundMap) {
            return;
        }

        var topLeftLatLon = Projection.tileToLatLon(x, y, z);
        var bottomRightLatLon = Projection.tileToLatLon(x + 1, y + 1, z);
        _mapTileCache[key] = [
            resolved,
            x,
            y,
            z,
            tileSize,
            topLeftLatLon,
            bottomRightLatLon,
        ];
        _pruneStaleTilesCoveredBy(topLeftLatLon, bottomRightLatLon);
        WatchUi.requestUpdate();
    }

    private function _mapScheduleRetry() as Void {
        _mapNextRetryAtMs = System.getTimer() + _mapRetryBackoffMs;
        _mapRetryBackoffMs *= 2;
        if (_mapRetryBackoffMs > MAP_MAX_RETRY_BACKOFF_MS) {
            _mapRetryBackoffMs = MAP_MAX_RETRY_BACKOFF_MS;
        }
        // Without this, needsRefetch sees zero drift from the failed request's own target and
        // never retries at all once the view is stationary, no matter how long the cooldown clears.
        _mapRequestedLat = null;
    }

    // Each tile's own two corners, not one shared scale - Mercator tiles vary in real height by
    // latitude, so a single ratio can't represent every row correctly. Also used for stale tiles,
    // whose own corners against the current focus/radius is what makes them redraw at the new scale.
    private function _drawMapTile(
        dc as Dc,
        tile as MapTile,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        focusLat as Float,
        focusLon as Float
    ) as Void {
        var bitmap = tile[0] as Graphics.BitmapType;
        var tileSize = tile[4] as Number;
        var topLeftLatLon = tile[5] as [Float, Float];
        var bottomRightLatLon = tile[6] as [Float, Float];
        var topLeft = Projection.toScreenF(
            focusLat,
            focusLon,
            topLeftLatLon[0],
            topLeftLatLon[1],
            cx,
            cy,
            radiusPx,
            radiusKm
        );
        var bottomRight = Projection.toScreenF(
            focusLat,
            focusLon,
            bottomRightLatLon[0],
            bottomRightLatLon[1],
            cx,
            cy,
            radiusPx,
            radiusKm
        );
        // Rounding to whole pixels avoids a per-tile AA/coverage seam at the shared edge,
        // even though adjacent tiles already compute that edge as float-identical.
        var left = Math.round(topLeft[0]);
        var top = Math.round(topLeft[1]);
        var right = Math.round(bottomRight[0]);
        var bottom = Math.round(bottomRight[1]);
        var scaleX = (right - left) / tileSize.toFloat();
        var scaleY = (bottom - top) / tileSize.toFloat();
        var xform = new Graphics.AffineTransform();
        xform.translate(left, top);
        xform.scale(scaleX, scaleY);
        dc.drawBitmap2(0, 0, bitmap, {
            :transform => xform,
            :filterMode => Graphics.FILTER_MODE_POINT,
        });
    }

    private function _latLonRectsOverlap(
        aTopLeft as [Float, Float],
        aBottomRight as [Float, Float],
        bTopLeft as [Float, Float],
        bBottomRight as [Float, Float]
    ) as Boolean {
        return (
            aBottomRight[0] < bTopLeft[0] and
            bBottomRight[0] < aTopLeft[0] and
            aTopLeft[1] < bBottomRight[1] and
            bTopLeft[1] < aBottomRight[1]
        );
    }

    // True if a needed tile's geographic footprint isn't already covered by a stale placeholder -
    // only areas with neither a fresh nor a stale tile need the "Loading..." text.
    private function _coveredByStaleTile(
        topLeftLatLon as [Float, Float],
        bottomRightLatLon as [Float, Float]
    ) as Boolean {
        for (var i = 0; i < _staleMapTiles.size(); i++) {
            var stale = _staleMapTiles[i];
            if (
                _latLonRectsOverlap(
                    topLeftLatLon,
                    bottomRightLatLon,
                    stale[5] as [Float, Float],
                    stale[6] as [Float, Float]
                )
            ) {
                return true;
            }
        }
        return false;
    }

    // Drops any stale tile the newly-arrived tile geographically overlaps - keeps peak memory close to one view's worth instead of both sets fully resident during the transition.
    private function _pruneStaleTilesCoveredBy(
        topLeftLatLon as [Float, Float],
        bottomRightLatLon as [Float, Float]
    ) as Void {
        if (_staleMapTiles.size() == 0) {
            return;
        }
        var kept = [] as Array<MapTile>;
        for (var i = 0; i < _staleMapTiles.size(); i++) {
            var stale = _staleMapTiles[i];
            if (
                !_latLonRectsOverlap(
                    topLeftLatLon,
                    bottomRightLatLon,
                    stale[5] as [Float, Float],
                    stale[6] as [Float, Float]
                )
            ) {
                kept.add(stale);
            }
        }
        _staleMapTiles = kept;

        var units = 0;
        for (var i = 0; i < kept.size(); i++) {
            units += (kept[i][4] as Number) == _mapClient.TILE_SIZE_HI ? 4 : 1;
        }
        var freshValues = _mapTileCache.values();
        for (var i = 0; i < freshValues.size(); i++) {
            units +=
                (freshValues[i][4] as Number) == _mapClient.TILE_SIZE_HI
                    ? 4
                    : 1;
        }
        if (units > MAP_STALE_HARD_CEILING_STD_UNITS) {
            _staleMapTiles = [] as Array<MapTile>;
        }
    }

    // Redrawn every frame, unthrottled - only the fetch itself is debounced.
    private function _drawBackgroundMap(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        focusLat as Float,
        focusLon as Float
    ) as Void {
        for (var i = 0; i < _staleMapTiles.size(); i++) {
            _drawMapTile(
                dc,
                _staleMapTiles[i],
                cx,
                cy,
                radiusPx,
                radiusKm,
                focusLat,
                focusLon
            );
        }

        var keys = _mapTileCache.keys();
        for (var i = 0; i < keys.size(); i++) {
            _drawMapTile(
                dc,
                _mapTileCache[keys[i] as String],
                cx,
                cy,
                radiusPx,
                radiusKm,
                focusLat,
                focusLon
            );
        }

        dc.setColor(COLOR_GRID_LABEL, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < _mapNeededTiles.size(); i++) {
            var needed = _mapNeededTiles[i];
            var nz = needed[0] as Number;
            var nx = needed[1] as Number;
            var ny = needed[2] as Number;
            var nSize = needed[3] as Number;
            var neededKey = _mapClient.tileKeyFor(nz, nx, ny, nSize);
            if (_mapTileCache.hasKey(neededKey)) {
                continue;
            }
            var pendingTopLeftLatLon = Projection.tileToLatLon(nx, ny, nz);
            var pendingBottomRightLatLon = Projection.tileToLatLon(
                nx + 1,
                ny + 1,
                nz
            );
            if (
                _coveredByStaleTile(
                    pendingTopLeftLatLon,
                    pendingBottomRightLatLon
                )
            ) {
                continue;
            }
            var pendingTopLeft = Projection.toScreenF(
                focusLat,
                focusLon,
                pendingTopLeftLatLon[0],
                pendingTopLeftLatLon[1],
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            var pendingBottomRight = Projection.toScreenF(
                focusLat,
                focusLon,
                pendingBottomRightLatLon[0],
                pendingBottomRightLatLon[1],
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            var midX = (pendingTopLeft[0] + pendingBottomRight[0]) / 2.0;
            var midY = (pendingTopLeft[1] + pendingBottomRight[1]) / 2.0;
            dc.drawText(
                midX.toNumber(),
                midY.toNumber(),
                _fontTiny,
                _mapLoadingText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    // Inner rings sit at real round-number km distances (like a map's own distance rings), not arbitrary N-way divisions.
    private function _drawChrome(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        topPanelH as Number
    ) as Void {
        if (Settings.showRangeRings) {
            var stepKm = _niceKmStep(radiusKm / RING_TARGET_COUNT);
            if (stepKm > 0.0) {
                var ringKm = stepKm;
                while (ringKm < radiusKm - 0.001) {
                    var ringPx = _round((ringKm * radiusPx) / radiusKm);
                    dc.setStroke(
                        DrawUtil.withAlpha(COLOR_RING, COLOR_RING_ALPHA)
                    );
                    dc.drawCircle(cx, cy, ringPx);
                    _drawRingLabel(
                        dc,
                        cx,
                        cy,
                        ringPx,
                        ringKm,
                        topPanelH,
                        COLOR_GRID_LABEL
                    );
                    ringKm += stepKm;
                }
            }
        }
        // Boundary ring drawn more solid, like a scope's detection edge - always shown, marks the zoom radius itself.
        dc.setStroke(DrawUtil.withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawCircle(cx, cy, radiusPx);
        // White, not the usual dim grid-label grey - this is the actual current zoom level, not a secondary reference ring.
        _drawRingLabel(dc, cx, cy, radiusPx, radiusKm, topPanelH, COLORS[0]);

        if (Settings.showRangeRings) {
            for (var deg = 0; deg < 360; deg += 30) {
                var cardinal = deg % 90 == 0;
                dc.setStroke(
                    DrawUtil.withAlpha(
                        COLOR_RING,
                        cardinal ? COLOR_TICK_ALPHA : COLOR_MINOR_TICK_ALPHA
                    )
                );
                _drawCompassTick(
                    dc,
                    cx,
                    cy,
                    radiusPx,
                    deg.toFloat(),
                    cardinal ? 8 : 4
                );
            }
        }
    }

    // Upper-right (45deg) so it doesn't collide with the top panel.
    private function _drawRingLabel(
        dc as Dc,
        cx as Number,
        cy as Number,
        ringPx as Number,
        ringKm as Float,
        topPanelH as Number,
        color as Number
    ) as Void {
        var theta = Math.toRadians(45.0);
        // Rounded, not truncated - .toNumber() truncates toward zero, biasing the label inward.
        var x = cx + Math.round(ringPx * Math.sin(theta)).toNumber();
        var y = cy - Math.round(ringPx * Math.cos(theta)).toNumber();
        if (y < topPanelH + 10) {
            return;
        }
        _drawGridLabel(dc, x, y, _formatKm(ringKm), color);
    }

    // Largest "nice" value (1/2/3/5 x 10^n) that fits within maxKm - same rule Leaflet's scale bar uses.
    private function _niceKmStep(maxKm as Float) as Float {
        if (maxKm <= 0.0) {
            return 0.0;
        }
        var pow10 = 1.0;
        while (pow10 * 10.0 <= maxKm) {
            pow10 *= 10.0;
        }
        while (pow10 > maxKm) {
            pow10 /= 10.0;
        }
        var d = maxKm / pow10;
        var mult =
            d >= 10.0
                ? 10.0
                : d >= 5.0
                  ? 5.0
                  : d >= 3.0
                    ? 3.0
                    : d >= 2.0
                      ? 2.0
                      : 1.0;
        return pow10 * mult;
    }

    private function _drawCompassTick(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        compassDeg as Float,
        tickLen as Number
    ) as Void {
        var theta = Math.toRadians(compassDeg);
        var sinT = Math.sin(theta);
        var cosT = Math.cos(theta);
        // Rounded, not truncated - .toNumber() truncates toward zero, biasing every tick inward.
        dc.drawLine(
            cx + Math.round(radiusPx * sinT).toNumber(),
            cy - Math.round(radiusPx * cosT).toNumber(),
            cx + Math.round((radiusPx - tickLen) * sinT).toNumber(),
            cy - Math.round((radiusPx - tickLen) * cosT).toNumber()
        );
    }

    // Angles are eyeballed compass bearings from the real device (0deg=up/north, clockwise).
    private function _drawButtonHints(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number
    ) as Void {
        var trueEdge =
            (dc.getWidth() < dc.getHeight() ? dc.getWidth() : dc.getHeight()) /
            2;
        var ringR = (radiusPx + trueEdge) / 2;

        var plusPos = _buttonHintPos(cx, cy, ringR, 270.0);
        var minusPos = _buttonHintPos(cx, cy, ringR, 240.0);
        var menuPos = _buttonHintPos(cx, cy, ringR, 60.0);
        var recenterPos = _buttonHintPos(cx, cy, ringR, 120.0);

        _drawPlusHint(dc, plusPos[0], plusPos[1]);
        _drawMinusHint(dc, minusPos[0], minusPos[1]);
        _drawMenuHint(dc, menuPos[0], menuPos[1]);
        _drawRecenterHint(dc, recenterPos[0], recenterPos[1]);
    }

    // Farthest a hint icon's own drawn pixels reach from its center - hints aren't rotated to the ring's
    // radial direction, so the worst case is the full diagonal of the largest icon (s=6 -> 6*sqrt(2) =~ 8.5px,
    // rounded up). A fixed geometric fact, not font-derived - Monkey C consts can't call Math.sqrt anyway.
    private const BUTTON_HINT_REACH_PX = 9;

    private function _buttonHintPos(
        cx as Number,
        cy as Number,
        ringR as Number,
        compassDeg as Float
    ) as [Number, Number] {
        var theta = Math.toRadians(compassDeg);
        // Rounded, not truncated - .toNumber() truncates toward zero, biasing every hint inward.
        var x = cx + Math.round(ringR * Math.sin(theta)).toNumber();
        var y = cy - Math.round(ringR * Math.cos(theta)).toNumber();
        return [x, y];
    }

    // Zoom in (KEY_UP). White, not COLOR_TEXT, to match the chevron's brightness.
    private function _drawPlusHint(dc as Dc, x as Number, y as Number) as Void {
        dc.setColor(COLORS[0], Graphics.COLOR_TRANSPARENT);
        var s = 6;
        dc.drawLine(x - s, y, x + s, y);
        dc.drawLine(x, y - s, x, y + s);
    }

    // Zoom out (KEY_DOWN).
    private function _drawMinusHint(
        dc as Dc,
        x as Number,
        y as Number
    ) as Void {
        dc.setColor(COLORS[0], Graphics.COLOR_TRANSPARENT);
        var s = 6;
        dc.drawLine(x - s, y, x + s, y);
    }

    // Menu (KEY_ENTER/KEY_MENU).
    private function _drawMenuHint(dc as Dc, x as Number, y as Number) as Void {
        dc.setColor(COLORS[0], Graphics.COLOR_TRANSPARENT);
        var s = 4;
        dc.drawLine(x - s, y - 3, x + s, y - 3);
        dc.drawLine(x - s, y, x + s, y);
        dc.drawLine(x - s, y + 3, x + s, y + 3);
    }

    // Recenter (KEY_ESC) - a crosshair with a gap, not a solid "+", so it doesn't read as the zoom-in hint.
    private function _drawRecenterHint(
        dc as Dc,
        x as Number,
        y as Number
    ) as Void {
        dc.setColor(COLORS[0], Graphics.COLOR_TRANSPARENT);
        var s = 6;
        var gap = 2;
        dc.drawLine(x, y - s, x, y - gap);
        dc.drawLine(x, y + gap, x, y + s);
        dc.drawLine(x - s, y, x - gap, y);
        dc.drawLine(x + gap, y, x + s, y);
    }

    // Zoom radius is labeled on the boundary ring instead (see _drawChrome); "No Signal" takes that old top-line slot here.
    private function _topPanelLines() as Array<[String, Number]> {
        var lines = [] as Array<[String, Number]>;
        lines.add(_fetchStatusLine());
        if (_centerLat != null && _centerLon != null) {
            lines.add([
                _formatLat(_centerLat as Float, true) +
                    " " +
                    _formatLon(_centerLon as Float, true),
                COLOR_TEXT,
            ]);
        }
        return lines;
    }

    private function _fetchStatusLine() as [String, Number] {
        if (!_lastFetchOk) {
            return _lastFetchTooMuchData
                ? [_tooBusyText, COLOR_WARN]
                : [_noSignalText, COLOR_EMERGENCY];
        }
        if (_fetchInFlight && !_viewHasFreshData) {
            return [_fetchingText, COLOR_GRID_LABEL];
        }
        return [_liveText, COLOR_SUCCESS];
    }

    private function _topPanelHeight() as Number {
        return _topPanelHeightFor(_topPanelLines());
    }

    private function _topPanelHeightFor(
        lines as Array<[String, Number]>
    ) as Number {
        return lines.size() * _topPanelLineHeight + 8;
    }

    // Takes lines rather than recomputing them - onUpdate already built them once for the height calc.
    private function _drawTopPanel(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        lines as Array<[String, Number]>
    ) as Void {
        var panelH = _topPanelHeightFor(lines);

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, dc.getWidth(), panelH);

        for (var i = 0; i < lines.size(); i++) {
            var line = lines[i];
            dc.setColor(line[1] as Number, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                4 + i * _topPanelLineHeight,
                _fontTiny,
                line[0] as String,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        if (_fetchInFlight) {
            _drawFetchSpinner(
                dc,
                dc.getWidth() - 12,
                _topPanelLineHeight / 2 + 4
            );
        }

        _drawPanelBorder(dc, panelH, cx, cy, radiusPx);
    }

    private const FETCH_SPINNER_R = 5;
    private const FETCH_SPINNER_DOT_R = 2;
    private const FETCH_SPINNER_PERIOD_MS = 1200;

    // A dot orbiting a ring, not a static dot - no rotational symmetry, so it still reads as motion at this redraw rate.
    private function _drawFetchSpinner(
        dc as Dc,
        x as Number,
        y as Number
    ) as Void {
        var theta =
            ((System.getTimer() % FETCH_SPINNER_PERIOD_MS).toFloat() /
                FETCH_SPINNER_PERIOD_MS) *
            2 *
            Math.PI;
        dc.setColor(COLOR_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(x, y, FETCH_SPINNER_R);
        // Rounded, not truncated - .toNumber() truncates toward zero, biasing the orbit inward.
        dc.fillCircle(
            x + Math.round(FETCH_SPINNER_R * Math.cos(theta)).toNumber(),
            y + Math.round(FETCH_SPINNER_R * Math.sin(theta)).toNumber(),
            FETCH_SPINNER_DOT_R
        );
    }

    private function _drawPanelBorder(
        dc as Dc,
        y as Number,
        cx as Number,
        cy as Number,
        radiusPx as Number
    ) as Void {
        var dy = (y - cy).abs();
        if (dy >= radiusPx) {
            return;
        }
        var halfW = DrawUtil.chordHalfExtent(radiusPx, dy);
        // COLOR_BOUNDARY_ALPHA, not COLOR_RING_ALPHA - reads as a continuation of the boundary ring, not a secondary ring.
        dc.setStroke(DrawUtil.withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawLine(cx - halfW, y, cx + halfW, y);
    }

    private function _drawLatLonGrid(
        dc as Dc,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        topPanelH as Number,
        bottomLimitY as Number
    ) as Void {
        var stepKm = GRID_STEP_KM[Settings.zoomIndex];
        var latStep = _kmToDeg(stepKm);
        var lonStep = _kmToDegLon(stepKm, focusLat);

        var latBase = Math.floor(focusLat / latStep) * latStep;
        for (var i = -4; i <= 4; i++) {
            var lat = latBase + i * latStep;
            var pt = Projection.toScreen(
                focusLat,
                focusLon,
                lat,
                focusLon,
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            var dy = (pt[1] - cy).abs();
            if (dy >= radiusPx) {
                continue;
            }
            var halfW = DrawUtil.chordHalfExtent(radiusPx, dy);
            dc.setStroke(DrawUtil.withAlpha(COLOR_GRID, COLOR_GRID_ALPHA));
            dc.drawLine(cx - halfW, pt[1], cx + halfW, pt[1]);
            if (pt[1] > topPanelH && pt[1] < bottomLimitY) {
                _drawGridLabel(
                    dc,
                    cx - halfW + _gridLabelInset,
                    pt[1],
                    _formatLat(lat, false),
                    COLOR_GRID_LABEL
                );
            }
        }

        var lonBase = Math.floor(focusLon / lonStep) * lonStep;
        for (var i = -4; i <= 4; i++) {
            var lon = lonBase + i * lonStep;
            var pt = Projection.toScreen(
                focusLat,
                focusLon,
                focusLat,
                lon,
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            var dx = (pt[0] - cx).abs();
            if (dx >= radiusPx) {
                continue;
            }
            var halfH = DrawUtil.chordHalfExtent(radiusPx, dx);
            var lineTop = cy - halfH;
            var lineBottom = cy + halfH;
            dc.setStroke(DrawUtil.withAlpha(COLOR_GRID, COLOR_GRID_ALPHA));
            dc.drawLine(pt[0], lineTop, pt[0], lineBottom);
            var labelY = lineTop > topPanelH ? lineTop : topPanelH + 10;
            if (labelY < lineBottom) {
                _drawGridLabel(
                    dc,
                    pt[0],
                    labelY,
                    _formatLon(lon, false),
                    COLOR_GRID_LABEL
                );
            }
        }
    }

    private function _drawGridLabel(
        dc as Dc,
        x as Number,
        y as Number,
        text as String,
        color as Number
    ) as Void {
        var dims = dc.getTextDimensions(text, _fontTiny);
        var padX = 3;
        var padY = 1;
        var boxW = dims[0] + padX * 2;
        var boxH = dims[1] + padY * 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x - boxW / 2, y - boxH / 2, boxW, boxH);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            x,
            y,
            _fontTiny,
            text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function _formatLat(lat as Float, precise as Boolean) as String {
        var s = precise ? lat.abs().format("%.4f") : lat.abs().format("%.2f");
        return s + (lat >= 0 ? "N" : "S");
    }

    private function _formatLon(lon as Float, precise as Boolean) as String {
        var s = precise ? lon.abs().format("%.4f") : lon.abs().format("%.2f");
        return s + (lon >= 0 ? "E" : "W");
    }

    // Falls back to the edge arrow whenever off-radar or inside a panel band, so the dot never renders on top of a panel.
    private function _drawUserMarker(
        dc as Dc,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        topPanelH as Number,
        bottomLimitY as Number
    ) as Void {
        var lat = _centerLat as Float;
        var lon = _centerLon as Float;
        var pos = Projection.toScreen(
            focusLat,
            focusLon,
            lat,
            lon,
            cx,
            cy,
            radiusPx,
            radiusKm
        );
        var dx = (pos[0] - cx).toFloat();
        var dy = (pos[1] - cy).toFloat();
        var pxDist = Math.sqrt(dx * dx + dy * dy);
        var obscured =
            pxDist > radiusPx || pos[1] < topPanelH || pos[1] > bottomLimitY;

        if (obscured) {
            var angle = Math.atan2(dy, dx);
            _drawOffscreenUserArrow(
                dc,
                cx,
                cy,
                radiusPx,
                angle,
                topPanelH,
                bottomLimitY
            );
            return;
        }

        dc.setColor(COLOR_USER, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(pos[0], pos[1], 5);
        dc.fillCircle(pos[0], pos[1], 2);
    }

    // Clamped so the arrow can't land inside the top/bottom panel bands - z-order alone isn't enough here.
    private function _drawOffscreenUserArrow(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        angle as Float,
        topPanelH as Number,
        bottomLimitY as Number
    ) as Void {
        var cosT = Math.cos(angle);
        var sinT = Math.sin(angle);
        var edgeR = (radiusPx - 14).toFloat();
        var pad = 10.0;

        if (sinT < -0.01 && cy + edgeR * sinT < topPanelH + pad) {
            var r = (topPanelH + pad - cy) / sinT;
            if (r > 10.0 && r < edgeR) {
                edgeR = r;
            }
        } else if (sinT > 0.01 && cy + edgeR * sinT > bottomLimitY - pad) {
            var r = (bottomLimitY - pad - cy) / sinT;
            if (r > 10.0 && r < edgeR) {
                edgeR = r;
            }
        }

        var ex = cx + edgeR * cosT;
        var ey = cy + edgeR * sinT;

        var local =
            [
                [7.0, 0.0],
                [-5.0, -4.0],
                [-5.0, 4.0],
            ] as Array<[Float, Float]>;
        var pts = [] as Array<[Float, Float]>;
        for (var i = 0; i < local.size(); i++) {
            var p = local[i];
            var x = p[0] * cosT - p[1] * sinT;
            var y = p[0] * sinT + p[1] * cosT;
            pts.add([ex + x, ey + y]);
        }

        dc.setColor(COLOR_USER, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(pts);
    }

    // Degrees of latitude spanning a given km distance - constant everywhere, unlike longitude.
    private function _kmToDeg(km as Float) as Float {
        return km / (Projection.METERS_PER_DEG_LAT / 1000.0);
    }

    // Longitude degrees shrink in real distance away from the equator (cos(lat)) - unlike latitude.
    private function _kmToDegLon(km as Float, atLat as Float) as Float {
        var metersPerDeg =
            Projection.METERS_PER_DEG_LAT * Math.cos(Math.toRadians(atLat));
        return (km * 1000.0) / metersPerDeg;
    }

    private function _rectsOverlap(
        a as [Number, Number, Number, Number],
        b as [Number, Number, Number, Number]
    ) as Boolean {
        return a[0] < b[2] && a[2] > b[0] && a[1] < b[3] && a[3] > b[1];
    }

    private function _reserveRect(
        hex as String,
        rect as [Number, Number, Number, Number]
    ) as Void {
        _reservedRects.add(
            [hex, rect[0], rect[1], rect[2], rect[3]] as
                [String, Number, Number, Number, Number]
        );
    }

    // Skips rects owned by hex itself - a label may sit over its own icon/chevron/reticle, only another's clips.
    private function _overlapsReserved(
        hex as String,
        rect as [Number, Number, Number, Number]
    ) as Boolean {
        for (var i = 0; i < _reservedRects.size(); i++) {
            var entry = _reservedRects[i];
            if ((entry[0] as String).equals(hex)) {
                continue;
            }
            var other =
                [entry[1], entry[2], entry[3], entry[4]] as
                [Number, Number, Number, Number];
            if (_rectsOverlap(rect, other)) {
                return true;
            }
        }
        return false;
    }

    // Scales RGB toward black - exactly equivalent to alpha-blending over the radar's pure black background.
    private function _dimColor(color as Number, factor as Float) as Number {
        var r = (((color >> 16) & 0xff) * factor).toNumber();
        var g = (((color >> 8) & 0xff) * factor).toNumber();
        var b = ((color & 0xff) * factor).toNumber();
        return (r << 16) | (g << 8) | b;
    }

    // Auto-hides on top of the user's own Settings while "too busy" - reverts once a normal response returns.
    private function _effectiveShowGroundVehicles() as Boolean {
        return Settings.showGroundVehicles && !_lastFetchTooMuchData;
    }

    private function _effectiveHideGroundedPlanes() as Boolean {
        return Settings.hideGroundedPlanes || _lastFetchTooMuchData;
    }

    private function _drawAircraft(
        dc as Dc,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float
    ) as Void {
        _lastDrawnPositions = [];
        _reservedRects = [];
        // Loop-invariant - computed once, not per aircraft.
        var showGroundVehicles = _effectiveShowGroundVehicles();
        var hideGroundedPlanes = _effectiveHideGroundedPlanes();

        for (var i = 0; i < _aircraft.size(); i++) {
            var ac = _aircraft[i];
            var distKm = Projection.distanceKm(
                focusLat,
                focusLon,
                ac.lat,
                ac.lon
            );
            if (distKm > radiusKm) {
                continue;
            }

            var isSelected =
                _selectedHex != null && ac.hex.equals(_selectedHex as String);

            // Selection overrides the decluttering filters below - a selected aircraft always draws.
            if (!isSelected) {
                var isGroundVehicle = ac.isGroundVehicle();
                if (!showGroundVehicles && isGroundVehicle) {
                    continue;
                }
                if (Settings.hideObstacles && ac.isObstacle()) {
                    continue;
                }
                if (hideGroundedPlanes && ac.onGround && !isGroundVehicle) {
                    continue;
                }
                if (Settings.hideMilitary && ac.military) {
                    continue;
                }
            }

            var pos = Projection.toScreen(
                focusLat,
                focusLon,
                ac.lat,
                ac.lon,
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            _lastDrawnPositions.add([ac.hex, pos[0], pos[1]]);

            if (isSelected && Settings.showSelectedTrail) {
                _drawSelectedTrail(
                    dc,
                    focusLat,
                    focusLon,
                    cx,
                    cy,
                    radiusPx,
                    radiusKm,
                    _colorForAircraft(ac)
                );
            }

            _drawAircraftIcon(dc, pos[0], pos[1], ac);
            if (Settings.showVertRateChevron) {
                _drawVertRateChevron(dc, pos[0], pos[1], ac);
            }
            if (ac.isEmergency()) {
                _drawEmergencyBadge(dc, pos[0], pos[1], ac);
            }

            // Reserved for every aircraft ahead of the label pass, so no label covers an icon or clips a chevron.
            _reserveRect(ac.hex, _iconRect(pos[0], pos[1], ac));
            if (Settings.showVertRateChevron) {
                var chevronRect = _chevronRect(pos[0], pos[1], ac);
                if (chevronRect != null) {
                    _reserveRect(
                        ac.hex,
                        chevronRect as [Number, Number, Number, Number]
                    );
                }
            }
            if (ac.isEmergency()) {
                _reserveRect(ac.hex, _emergencyBadgeRect(pos[0], pos[1], ac));
            }

            if (isSelected) {
                _drawSelectionReticle(dc, pos[0], pos[1], ac);
                _reserveRect(ac.hex, _selectionReticleRect(pos[0], pos[1], ac));
            }
        }

        // A separate pass, after every icon - otherwise a later label could paint over an earlier icon.
        if (Settings.labelsEnabled) {
            // Loop-invariant - same for every aircraft's label this frame, not re-looked-up per aircraft.
            var showCallsign = Settings.isLabelFieldEnabled("callsign");
            var showSpeed = Settings.isLabelFieldEnabled("speed");
            var showAltitude = Settings.isLabelFieldEnabled("altitude");
            var lineH = dc.getTextDimensions("Ag", _fontTiny)[1];
            var selectedIndex = -1;
            if (_selectedHex != null) {
                for (var i = 0; i < _lastDrawnPositions.size(); i++) {
                    if (
                        (_lastDrawnPositions[i][0] as String).equals(
                            _selectedHex as String
                        )
                    ) {
                        selectedIndex = i;
                        break;
                    }
                }
            }
            // Drawn first so its rect is already reserved - an overlapping label loses the spot instead of stacking.
            if (selectedIndex >= 0) {
                var selEntry = _lastDrawnPositions[selectedIndex];
                var selAc = _aircraftByHex[selEntry[0] as String];
                if (selAc != null) {
                    _drawAircraftLabel(
                        dc,
                        selEntry[1] as Number,
                        selEntry[2] as Number,
                        selAc as Aircraft,
                        true,
                        showCallsign,
                        showSpeed,
                        showAltitude,
                        lineH
                    );
                }
            }
            var order = _labelDrawOrder(selectedIndex);
            for (var oi = 0; oi < order.size(); oi++) {
                var entry = _lastDrawnPositions[order[oi]];
                var hex = entry[0] as String;
                var ac = _aircraftByHex[hex];
                if (ac == null) {
                    continue;
                }
                _drawAircraftLabel(
                    dc,
                    entry[1] as Number,
                    entry[2] as Number,
                    ac as Aircraft,
                    false,
                    showCallsign,
                    showSpeed,
                    showAltitude,
                    lineH
                );
            }

            // Re-drawn on top of every label, so the selected aircraft's icon/reticle/chevron stay visible above others.
            if (selectedIndex >= 0) {
                var topEntry = _lastDrawnPositions[selectedIndex];
                var topAc = _aircraftByHex[topEntry[0] as String];
                if (topAc != null) {
                    _drawSelectedIconOnTop(
                        dc,
                        topEntry[1] as Number,
                        topEntry[2] as Number,
                        topAc as Aircraft
                    );
                }
            }
        }
    }

    // Bigger-class aircraft's label wins any overlap - plain insertion sort, cheap since on-screen counts are small.
    // Index and scale travel together as one pair per entry, so a sort step can't move one without the other.
    private function _labelDrawOrder(selectedIndex as Number) as Array<Number> {
        var pairs = [] as Array<[Number, Float]>;
        for (var i = 0; i < _lastDrawnPositions.size(); i++) {
            if (i != selectedIndex) {
                pairs.add([i, _sizeScaleForIndex(i)] as [Number, Float]);
            }
        }
        for (var i = 1; i < pairs.size(); i++) {
            var key = pairs[i];
            var j = i - 1;
            while (j >= 0 && (pairs[j] as [Number, Float])[1] < key[1]) {
                pairs[j + 1] = pairs[j];
                j -= 1;
            }
            pairs[j + 1] = key;
        }
        var order = [] as Array<Number>;
        for (var i = 0; i < pairs.size(); i++) {
            order.add((pairs[i] as [Number, Float])[0]);
        }
        return order;
    }

    private function _sizeScaleForIndex(i as Number) as Float {
        var ac = _aircraftByHex[_lastDrawnPositions[i][0] as String];
        return ac != null ? _sizeScaleForAircraft(ac as Aircraft) : 0.0;
    }

    private function _drawSelectedIconOnTop(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        _drawAircraftIcon(dc, x, y, ac);
        if (Settings.showVertRateChevron) {
            _drawVertRateChevron(dc, x, y, ac);
        }
        if (ac.isEmergency()) {
            _drawEmergencyBadge(dc, x, y, ac);
        }
        _drawSelectionReticle(dc, x, y, ac);
    }

    // Ground/taxi segments dim the same color instead of using gray, so the dashed part still reads as one track.
    private const TRAIL_DASH_PX = 5.0;
    private const TRAIL_GAP_PX = 4.0;
    private const TRAIL_MAX_DASHES_PER_SEGMENT = 24;
    private const COLOR_TRAIL_GROUND_ALPHA = DrawUtil.ALPHA_55;

    private function _drawSelectedTrail(
        dc as Dc,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        trailColor as Number
    ) as Void {
        if (_selectedTrack.size() < 2) {
            return;
        }

        var prevScreen = null as Array<Number>?;
        var prevPt = null as [Float, Float, Number, Boolean]?;
        // Carried across consecutive dashed segments so closely spaced live-polled points (a taxiing
        // aircraft can move under one dash length between polls) still alternate instead of each tiny
        // segment drawing as one unbroken dash.
        var dashPhase = 0.0;
        for (var i = 0; i < _selectedTrack.size(); i++) {
            var pt = _selectedTrack[i];
            var screen = Projection.toScreen(
                focusLat,
                focusLon,
                pt[0],
                pt[1],
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            if (prevScreen != null && prevPt != null) {
                var p0 = prevScreen as Array<Number>;
                var p1 = prevPt as [Float, Float, Number, Boolean];
                if ((p1[3] as Boolean) || (pt[3] as Boolean)) {
                    dc.setStroke(
                        DrawUtil.withAlpha(trailColor, COLOR_TRAIL_GROUND_ALPHA)
                    );
                    dashPhase = _drawDashedLine(
                        dc,
                        p0[0],
                        p0[1],
                        screen[0],
                        screen[1],
                        dashPhase
                    );
                } else {
                    dc.setStroke(
                        DrawUtil.withAlpha(trailColor, COLOR_TRAIL_ALPHA)
                    );
                    dc.drawLine(p0[0], p0[1], screen[0], screen[1]);
                    dashPhase = 0.0;
                }
            }
            prevScreen = screen;
            prevPt = pt;
        }
    }

    // No native dashed-stroke primitive - subdivides the segment into fixed-length dash/gap pairs.
    // phase is the distance already traveled into the current dash/gap cycle when this segment starts,
    // and the return value is the phase to carry into the next segment of the same run.
    private function _drawDashedLine(
        dc as Dc,
        x0 as Number,
        y0 as Number,
        x1 as Number,
        y1 as Number,
        phase as Float
    ) as Float {
        var dx = (x1 - x0).toFloat();
        var dy = (y1 - y0).toFloat();
        var length = Math.sqrt(dx * dx + dy * dy);
        if (length < 1.0) {
            return phase;
        }
        var ux = dx / length;
        var uy = dy / length;
        var step = TRAIL_DASH_PX + TRAIL_GAP_PX;
        var endGlobal = phase + length;
        // phase is always a prior return value, already reduced mod step, so cycle 0 always covers it.
        var k = 0;
        for (var i = 0; i < TRAIL_MAX_DASHES_PER_SEGMENT; i++) {
            var dashGlobalStart = k * step;
            if (dashGlobalStart > endGlobal) {
                break;
            }
            var dashGlobalEnd = dashGlobalStart + TRAIL_DASH_PX;
            var clampedStart =
                dashGlobalStart > phase ? dashGlobalStart : phase;
            var clampedEnd =
                dashGlobalEnd < endGlobal ? dashGlobalEnd : endGlobal;
            if (clampedEnd > clampedStart) {
                var dStart = clampedStart - phase;
                var dEnd = clampedEnd - phase;
                dc.drawLine(
                    (x0 + ux * dStart).toNumber(),
                    (y0 + uy * dStart).toNumber(),
                    (x0 + ux * dEnd).toNumber(),
                    (y0 + uy * dEnd).toNumber()
                );
            }
            k += 1;
        }
        return endGlobal - Math.floor(endGlobal / step) * step;
    }

    private const GROUNDED_DIM_FACTOR = 0.45;
    // A position this old hasn't actually moved across several poll cycles - likely a fringe-of-coverage ghost.
    private const STALE_POSITION_SEC = 15.0;
    private const STALE_DIM_FACTOR = 0.55;
    // Tied to source PNGs' 3px/unit rendering - on-screen icon size stays constant if that changes.
    private const ICON_BASE_SCALE = 0.226667;
    private const ICON_RECT_MARGIN = 2;

    // Real tables/classification live in AircraftClassifier - cached per aircraft until the next fetch result.
    private function _classify(
        ac as Aircraft
    ) as [String, String, Float, Number] {
        var cached = _classifyCache[ac.hex];
        if (cached != null) {
            return cached as [String, String, Float, Number];
        }
        var cat = AircraftClassifier.effectiveCategory(ac);
        var shape = AircraftClassifier._shapeKeyForCategory(ac, cat);
        var scale = AircraftClassifier._sizeScaleForCategory(cat);
        var halfExtent = AircraftClassifier.iconHalfExtentForShape(
            shape,
            ICON_BASE_SCALE * scale
        );
        var result =
            [cat, shape, scale, halfExtent] as [String, String, Float, Number];
        _classifyCache[ac.hex] = result;
        return result;
    }

    private function _iconHalfExtent(ac as Aircraft) as Number {
        return _classify(ac)[3];
    }

    private function _iconRect(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number, Number] {
        var half = _iconHalfExtent(ac) + ICON_RECT_MARGIN;
        return (
            [x - half, y - half, x + half, y + half] as
            [Number, Number, Number, Number]
        );
    }

    // Helicopters use a real rotated body silhouette matched by type, same as fixed-wing - no separate rotor overlay.
    private function _drawAircraftIcon(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var color = _colorForAircraft(ac);
        if (Settings.dimGroundedAircraft && ac.onGround) {
            color = _dimColor(color, GROUNDED_DIM_FACTOR);
        }
        var age = ac.positionAgeSec;
        if (
            Settings.dimStaleAircraft &&
            age != null &&
            (age as Float) >= STALE_POSITION_SEC
        ) {
            color = _dimColor(color, STALE_DIM_FACTOR);
        }
        _drawIconVariant(dc, x, y, ac, color);
    }

    // Fixed corner offset, not centered on the icon - centered markers looked off-center against asymmetric icons.
    private const EMERGENCY_BADGE_R = 7;
    private const EMERGENCY_BADGE_MARGIN = 2;
    private const EMERGENCY_BADGE_EXTRA_CLEARANCE = 10;
    // Up-left, same angle+radius convention as _chevronCenter (theta=0 is up, clockwise) - sin/cos of a fixed
    // 315-degree angle, precomputed since the angle itself never varies.
    private const EMERGENCY_BADGE_SIN = -0.70710678;
    private const EMERGENCY_BADGE_COS = 0.70710678;

    private function _emergencyBadgeCenter(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number] {
        var r = (
            _iconHalfExtent(ac) +
            ICON_MARKER_CLEARANCE +
            EMERGENCY_BADGE_EXTRA_CLEARANCE
        ).toFloat();
        // Rounded, not truncated - .toNumber() truncates toward zero, biasing the badge toward the icon.
        return (
            [
                Math.round(x + r * EMERGENCY_BADGE_SIN).toNumber(),
                Math.round(y - r * EMERGENCY_BADGE_COS).toNumber(),
            ] as [Number, Number]
        );
    }

    private function _drawEmergencyBadge(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var c = _emergencyBadgeCenter(x, y, ac);
        DrawUtil.drawWarningIcon(
            dc,
            c[0],
            c[1],
            EMERGENCY_BADGE_R,
            COLOR_EMERGENCY
        );
    }

    private function _emergencyBadgeRect(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number, Number] {
        var c = _emergencyBadgeCenter(x, y, ac);
        var r = EMERGENCY_BADGE_R + EMERGENCY_BADGE_MARGIN;
        return (
            [c[0] - r, c[1] - r, c[0] + r, c[1] + r] as
            [Number, Number, Number, Number]
        );
    }

    private const SELECTION_ARROW_LEN = 7.0;
    private const SELECTION_ARROW_WIDTH = 5.0;
    private const SELECTION_RECT_MARGIN = 2;
    // Shared clearance past the icon's own extent - both the reticle and vert-rate chevron use this, not separate radii.
    private const ICON_MARKER_CLEARANCE = 6;

    // Shared by _drawSelectionReticle and _selectionReticleRect - [tipY, baseY, halfW].
    private function _selectionReticleGeometry(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number] {
        var scale = _sizeScaleForAircraft(ac);
        var gap = _iconHalfExtent(ac) + ICON_MARKER_CLEARANCE;
        var tipY = y - gap;
        var baseY = tipY - (SELECTION_ARROW_LEN * scale).toNumber();
        var halfW = (SELECTION_ARROW_WIDTH * scale).toNumber();
        return [tipY, baseY, halfW] as [Number, Number, Number];
    }

    // A small triangle above the icon, tip pointing down - doesn't need to precisely frame the icon's own extent.
    private function _drawSelectionReticle(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var geom = _selectionReticleGeometry(x, y, ac);
        var tipY = geom[0];
        var baseY = geom[1];
        var halfW = geom[2];
        dc.setColor(COLOR_SELECTED, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([
            [x, tipY],
            [x - halfW, baseY],
            [x + halfW, baseY],
        ]);
    }

    private function _selectionReticleRect(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number, Number] {
        var geom = _selectionReticleGeometry(x, y, ac);
        var tipY = geom[0];
        var baseY = geom[1];
        var halfW = geom[2];
        return (
            [
                x - halfW - SELECTION_RECT_MARGIN,
                baseY - SELECTION_RECT_MARGIN,
                x + halfW + SELECTION_RECT_MARGIN,
                tipY + SELECTION_RECT_MARGIN,
            ] as [Number, Number, Number, Number]
        );
    }

    private function _bitmapForShape(shape as String) as Graphics.BitmapType {
        var cached = _iconBitmapCache[shape];
        if (cached != null) {
            return cached as Graphics.BitmapType;
        }
        var bmp =
            WatchUi.loadResource(ICON_RESOURCE_IDS[shape] as ResourceId) as
            Graphics.BitmapType;
        _iconBitmapCache[shape] = bmp;
        return bmp;
    }

    private function _drawIconVariant(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        color as Number
    ) as Void {
        var shape = _shapeKeyForAircraft(ac);
        var heading = ac.heading;
        var theta =
            heading != null && AircraftClassifier.shapeRotates(shape)
                ? Math.toRadians(heading)
                : 0.0;

        var scale = ICON_BASE_SCALE * _sizeScaleForAircraft(ac);
        var pivot = AircraftClassifier.ICON_PIVOT[shape];
        var halfW = pivot != null ? (pivot as [Float, Float])[0] : 30.0;
        var halfH = pivot != null ? (pivot as [Float, Float])[1] : 30.0;

        var tf = new Graphics.AffineTransform();
        tf.translate(x.toFloat(), y.toFloat());
        tf.rotate(theta);
        tf.scale(scale, scale);
        tf.translate(-halfW, -halfH);

        dc.drawBitmap2(0, 0, _bitmapForShape(shape), {
            :transform => tf,
            :tintColor => color,
            // Default (nearest-neighbor) is jagged at this rotation/downscale ratio - bilinear smooths it.
            :filterMode => Graphics.FILTER_MODE_BILINEAR,
        });
    }

    private const VERT_RATE_THRESHOLD_FPM = 150.0;
    private const CHEVRON_ANGLE_CLIMB_DEG = 45.0;
    private const CHEVRON_ANGLE_DESCEND_DEG = 135.0;
    private const CHEVRON_RECT_HALF = 4;

    // Shared by _drawVertRateChevron and _chevronRect, so the declutter rect matches where it actually draws.
    private function _chevronCenter(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number]? {
        var rate = ac.vertRate;
        if (rate == null or (rate as Float).abs() < VERT_RATE_THRESHOLD_FPM) {
            return null;
        }
        var climbing = (rate as Float) > 0;
        // Angle+radius past the icon's extent, not a flat offset, so it clears small icons too.
        var r = (_iconHalfExtent(ac) + ICON_MARKER_CLEARANCE).toFloat();
        var theta = Math.toRadians(
            climbing ? CHEVRON_ANGLE_CLIMB_DEG : CHEVRON_ANGLE_DESCEND_DEG
        );
        // Rounded, not truncated - .toNumber() truncates toward zero, biasing the chevron toward the icon.
        var cx = x + Math.round(r * Math.sin(theta)).toNumber();
        var cy = y - Math.round(r * Math.cos(theta)).toNumber();
        return [cx, cy] as [Number, Number];
    }

    private function _drawVertRateChevron(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var center = _chevronCenter(x, y, ac);
        if (center == null) {
            return;
        }
        var cx = center[0] as Number;
        var cy = center[1] as Number;
        var dir = (ac.vertRate as Float) > 0 ? 1 : -1;
        dc.setColor(_colorForAircraft(ac), Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 3, cy + dir * 3, cx, cy);
        dc.drawLine(cx, cy, cx + 3, cy + dir * 3);
    }

    private function _chevronRect(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number, Number]? {
        var center = _chevronCenter(x, y, ac);
        if (center == null) {
            return null;
        }
        var cx = center[0] as Number;
        var cy = center[1] as Number;
        return (
            [
                cx - CHEVRON_RECT_HALF,
                cy - CHEVRON_RECT_HALF,
                cx + CHEVRON_RECT_HALF,
                cy + CHEVRON_RECT_HALF,
            ] as [Number, Number, Number, Number]
        );
    }

    // Real tables/classification live in AircraftClassifier - all three read the cached _classify() result.
    private function _effectiveCategory(ac as Aircraft) as String {
        return _classify(ac)[0];
    }

    private function _shapeKeyForAircraft(ac as Aircraft) as String {
        return _classify(ac)[1];
    }

    private function _sizeScaleForAircraft(ac as Aircraft) as Float {
        return _classify(ac)[2];
    }

    private function _colorForAircraft(ac as Aircraft) as Number {
        if (Settings.singleColorMode) {
            return COLOR_AIRCRAFT_DEFAULT;
        }
        if (ac.military) {
            return COLOR_MILITARY;
        }
        var cat = _effectiveCategory(ac);
        if (cat.equals("A7")) {
            return COLOR_HELICOPTER;
        }
        if (cat.equals("A1")) {
            return COLOR_AIRCRAFT_LIGHT;
        }
        if (cat.equals("A3") || cat.equals("A4") || cat.equals("A5")) {
            return COLOR_AIRCRAFT_HEAVY;
        }
        if (cat.equals("A6")) {
            return COLOR_AIRCRAFT_FAST;
        }
        return COLOR_AIRCRAFT_DEFAULT;
    }

    private function _round(v as Float) as Number {
        return (v + (v >= 0 ? 0.5 : -0.5)).toNumber();
    }

    private function _roundHeading(v as Float) as Number {
        return ((_round(v) % 360) + 360) % 360;
    }

    private var _labelOverlapMarginPx as Number = 4;
    private var _labelLineGapPx as Number = 2;
    // Scaled by aircraft size like the reticle/icon, with margin to clear the reticle at every size tier.
    private var _labelVoffsetBase as Float = 18.0;

    // Two rows (callsign / speed+altitude), not one wide line - narrower footprint, fewer overlap hides.
    // No background rect, and fields keep the compact/full-detail views' own colors, not one flat color.
    private function _drawAircraftLabel(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        isSelected as Boolean,
        showCallsign as Boolean,
        showSpeed as Boolean,
        showAltitude as Boolean,
        lineH as Number
    ) as Void {
        var lines = _buildLabelLinesCached(
            ac,
            showCallsign,
            showSpeed,
            showAltitude
        );
        var top = lines[0] as Array<DrawUtil.ValueRun>;
        var bottom = lines[1] as Array<DrawUtil.ValueRun>;
        if (top.size() == 0 && bottom.size() == 0) {
            return;
        }

        // Measured once here and reused below for drawing - runWidth() is a real getTextDimensions() call
        // per run, and this runs for every visible labeled aircraft, every redraw.
        var topM = top.size() > 0 ? _measureSegments(dc, top) : null;
        var bottomM = bottom.size() > 0 ? _measureSegments(dc, bottom) : null;
        var topW = topM != null ? (topM as [Number, Array<Number>])[0] : 0;
        var bottomW =
            bottomM != null ? (bottomM as [Number, Array<Number>])[0] : 0;

        var width = topW > bottomW ? topW : bottomW;
        var height = 0;
        if (top.size() > 0) {
            height += lineH;
        }
        if (bottom.size() > 0) {
            height += lineH;
        }
        if (top.size() > 0 && bottom.size() > 0) {
            height += _labelLineGapPx;
        }

        var textY =
            y + (_labelVoffsetBase * _sizeScaleForAircraft(ac)).toNumber();
        var rect =
            [
                x - width / 2 - _labelOverlapMarginPx,
                textY - _labelOverlapMarginPx,
                x + width / 2 + _labelOverlapMarginPx,
                textY + height + _labelOverlapMarginPx,
            ] as [Number, Number, Number, Number];
        // Selection overrides the declutter-by-overlap check too, same as the icon/reticle/trail filters above.
        if (!isSelected && _overlapsReserved(ac.hex, rect)) {
            return;
        }
        _reserveRect(ac.hex, rect);

        var lineY = textY;
        if (topM != null) {
            var m = topM as [Number, Array<Number>];
            _drawMeasuredSegments(dc, x, lineY, top, m[1], m[0]);
            lineY += lineH + _labelLineGapPx;
        }
        if (bottomM != null) {
            var m = bottomM as [Number, Array<Number>];
            _drawMeasuredSegments(dc, x, lineY, bottom, m[1], m[0]);
        }
    }

    private function _measureSegments(
        dc as Dc,
        segments as Array<DrawUtil.ValueRun>
    ) as [Number, Array<Number>] {
        var widths = [] as Array<Number>;
        var totalW = -_segmentGapPx;
        for (var i = 0; i < segments.size(); i++) {
            var w = DrawUtil.runWidth(dc, _fontTiny, segments[i]);
            widths.add(w);
            totalW += w + _segmentGapPx;
        }
        return [totalW, widths] as [Number, Array<Number>];
    }

    // Draws with widths already known - unlike _drawSegmentedLine, doesn't re-measure each run itself.
    private function _drawMeasuredSegments(
        dc as Dc,
        cx as Number,
        y as Number,
        segments as Array<DrawUtil.ValueRun>,
        widths as Array<Number>,
        totalW as Number
    ) as Void {
        var x = cx - Math.round(totalW / 2.0).toNumber();
        for (var i = 0; i < segments.size(); i++) {
            DrawUtil.drawRun(dc, x, y, _fontTiny, segments[i]);
            x += (widths[i] as Number) + _segmentGapPx;
        }
    }

    // Rebuilds only per-aircraft when its data or the label settings change, not on every redraw.
    private function _buildLabelLinesCached(
        ac as Aircraft,
        showCallsign as Boolean,
        showSpeed as Boolean,
        showAltitude as Boolean
    ) as [Array<DrawUtil.ValueRun>, Array<DrawUtil.ValueRun>] {
        var flags =
            [
                showCallsign,
                showSpeed,
                showAltitude,
                Settings.singleColorMode,
                Settings.useMetricUnits,
            ] as [Boolean, Boolean, Boolean, Boolean, Boolean];
        var cachedFlags = _labelLinesCacheFlags;
        if (
            cachedFlags == null or
            cachedFlags[0] != flags[0] or
            cachedFlags[1] != flags[1] or
            cachedFlags[2] != flags[2] or
            cachedFlags[3] != flags[3] or
            cachedFlags[4] != flags[4]
        ) {
            _labelLinesCache = {};
            _labelLinesCacheFlags = flags;
        }
        var cached = _labelLinesCache[ac.hex];
        if (cached != null) {
            return cached;
        }
        var lines = _buildLabelLines(ac, showCallsign, showSpeed, showAltitude);
        _labelLinesCache[ac.hex] = lines;
        return lines;
    }

    // Same colors as the compact/full detail views (callsign=aircraft, speed=yellow, altitude=blue).
    // A label is just the at-a-glance version of the same data - it should read consistently, not as one flat color.
    private function _buildLabelLines(
        ac as Aircraft,
        showCallsign as Boolean,
        showSpeed as Boolean,
        showAltitude as Boolean
    ) as [Array<DrawUtil.ValueRun>, Array<DrawUtil.ValueRun>] {
        var top = [] as Array<DrawUtil.ValueRun>;
        if (showCallsign) {
            var cs = ac.flight;
            if (cs != null && cs.length() > 0) {
                top.add(DrawUtil.plainRun(cs as String, _colorForAircraft(ac)));
            }
        }

        var bottom = [] as Array<DrawUtil.ValueRun>;
        if (showSpeed && ac.gs != null) {
            bottom.add(
                DrawUtil.plainRun(
                    _formatSpeedKt(_round(ac.gs as Float)),
                    COLOR_SPEED
                )
            );
        }
        if (showAltitude) {
            if (ac.onGround) {
                bottom.add(DrawUtil.plainRun("GND", COLOR_ALT));
            } else if (ac.altBaro != null) {
                bottom.add(
                    DrawUtil.plainRun(
                        _formatAltitude(ac.altBaro as Number),
                        COLOR_ALT
                    )
                );
            }
        }

        return (
            [top, bottom] as
            [Array<DrawUtil.ValueRun>, Array<DrawUtil.ValueRun>]
        );
    }

    // Takes lines rather than recomputing them - onUpdate already built them once for the height calc.
    private function _drawDetailPanel(
        dc as Dc,
        cx as Number,
        cy as Number,
        h as Number,
        radiusPx as Number,
        lines as Array<Array<DrawUtil.ValueRun> >
    ) as Void {
        if (lines.size() == 0) {
            return;
        }

        var panelH = _detailPanelHeightFor(lines);
        var panelY = h - panelH;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        // Starts one row below panelY, leaving that pixel for _drawPanelBorder's line, not bare black.
        // Mirrors the top panel, which stops one row short of its own border for the same reason.
        dc.fillRectangle(0, panelY + 1, dc.getWidth(), panelH - 1);

        for (var i = 0; i < lines.size(); i++) {
            _drawSegmentedLine(
                dc,
                cx,
                panelY + 4 + i * _detailPanelLineHeight,
                lines[i] as Array<DrawUtil.ValueRun>
            );
        }

        _drawPanelBorder(dc, panelY, cx, cy, radiusPx);
        _drawChevronUp(dc, cx, panelY - _chevronMarginPx, CHEVRON_SIZE_PX);
    }

    // 0 when nothing is selected, so callers can treat "no panel" and "empty panel" the same.
    private function _detailPanelHeight(ac as Aircraft) as Number {
        return _detailPanelHeightFor(_buildDetailLines(ac));
    }

    private function _detailPanelHeightFor(
        lines as Array<Array<DrawUtil.ValueRun> >
    ) as Number {
        return lines.size() == 0
            ? 0
            : lines.size() * _detailPanelLineHeight + 8;
    }

    private var _chevronMarginPx as Number = 20;
    // Glyph size itself stays a fixed pixel constant - it's a plain vector chevron, not text.
    private const CHEVRON_SIZE_PX = 7;
    // Extra tap area above the panel's top edge, covering the chevron - so the chevron itself feels tappable.
    private const CHEVRON_TAP_MARGIN_PX = 28;

    // "There's more above" affordance - a plain line like _drawMinusHint/_drawMenuHint, no font glyph.
    // Full white, not COLOR_TEXT, since it's an affordance, not body text - reads brighter than the panel content.
    private function _drawChevronUp(
        dc as Dc,
        x as Number,
        y as Number,
        s as Number
    ) as Void {
        dc.setColor(COLORS[0], Graphics.COLOR_TRANSPARENT);
        DrawUtil.drawChevron(dc, x, y, s, true);
    }

    private var _segmentGapPx as Number = 6;

    private function _drawSegmentedLine(
        dc as Dc,
        cx as Number,
        y as Number,
        segments as Array<DrawUtil.ValueRun>
    ) as Void {
        if (segments.size() == 0) {
            return;
        }
        var measured = _measureSegments(dc, segments);
        _drawMeasuredSegments(
            dc,
            cx,
            y,
            segments,
            measured[1] as Array<Number>,
            measured[0] as Number
        );
    }

    // Rebuilds only when the selection/data actually changes, not on every redraw (e.g. every drag frame).
    private function _buildDetailLinesCached(
        ac as Aircraft
    ) as Array<Array<DrawUtil.ValueRun> > {
        var flags =
            [Settings.singleColorMode, Settings.useMetricUnits] as
            [Boolean, Boolean];
        var cachedFlags = _detailLinesCacheFlags;
        if (
            cachedFlags == null or
            cachedFlags[0] != flags[0] or
            cachedFlags[1] != flags[1]
        ) {
            _detailLinesCacheHex = null;
            _detailLinesCacheFlags = flags;
        }
        var cache = _detailLinesCache;
        var cacheHex = _detailLinesCacheHex;
        if (cache != null and cacheHex != null and cacheHex.equals(ac.hex)) {
            return cache;
        }
        var lines = _buildDetailLines(ac);
        _detailLinesCache = lines;
        _detailLinesCacheHex = ac.hex;
        return lines;
    }

    // Curated, not exhaustive - tas/vert-rate/nav-target/squawk moved to _buildFullDetailRows to keep this panel short.
    private function _buildDetailLines(
        ac as Aircraft
    ) as Array<Array<DrawUtil.ValueRun> > {
        var lines = [] as Array<Array<DrawUtil.ValueRun> >;

        // Emergency only - safety-critical, always the first thing shown, not buried below alt/speed/heading.
        if (ac.isEmergency()) {
            var label =
                ac.squawk != null
                    ? "EMERG " + (ac.squawk as String)
                    : "EMERGENCY";
            lines.add([DrawUtil.plainRun(label, COLOR_EMERGENCY)]);
        }

        var idSegs = [] as Array<DrawUtil.ValueRun>;
        idSegs.add(
            DrawUtil.plainRun(
                ac.flight != null && (ac.flight as String).length() > 0
                    ? ac.flight as String
                    : ac.hex,
                _colorForAircraft(ac)
            )
        );
        if (ac.registration != null) {
            idSegs.add(
                DrawUtil.plainRun(ac.registration as String, COLOR_IDENTITY)
            );
        }
        var badgeParts = [] as Array<String>;
        if (ac.spi) {
            badgeParts.add("IDENT");
        }
        if (ac.alertFlag) {
            badgeParts.add("ALERT");
        }
        if (badgeParts.size() > 0) {
            idSegs.add(
                DrawUtil.plainRun(
                    _join(badgeParts, " "),
                    ac.isEmergency() ? COLOR_EMERGENCY : COLOR_WARN
                )
            );
        }
        lines.add(idSegs);

        var typeStr =
            ac.typeDesc != null
                ? ac.typeDesc as String
                : ac.typeCode != null
                  ? ac.typeCode as String
                  : "";
        if (typeStr.length() > 0) {
            lines.add([DrawUtil.plainRun(typeStr, COLOR_IDENTITY)]);
        }

        var statSegs = [] as Array<DrawUtil.ValueRun>;
        if (ac.onGround) {
            statSegs.add(DrawUtil.plainRun("GND", COLOR_ALT));
        } else if (ac.altBaro != null) {
            statSegs.add(
                DrawUtil.plainRun(
                    _formatAltitude(ac.altBaro as Number),
                    COLOR_ALT
                )
            );
        }
        if (ac.gs != null) {
            statSegs.add(
                DrawUtil.plainRun(
                    _formatSpeedKt(_round(ac.gs as Float)),
                    COLOR_SPEED
                )
            );
        }
        if (ac.heading != null) {
            statSegs.add(
                [
                    _roundHeading(ac.heading as Float).toString(),
                    COLOR_HDG,
                    :degree,
                    "",
                ] as DrawUtil.ValueRun
            );
        }
        if (statSegs.size() > 0) {
            lines.add(statSegs);
        }

        var trackStatus = "";
        var trackColor = COLOR_GRID_LABEL;
        if (_trackFetchInFlight) {
            trackStatus = "Loading Track...";
        } else if (_trackHasHistory) {
            trackStatus = "Track Loaded";
            trackColor = COLOR_SUCCESS;
        } else {
            trackStatus = "No Track History";
        }
        lines.add([DrawUtil.plainRun(trackStatus, trackColor)]);

        return lines;
    }

    // Plain (non-glyph) grid cell - the common case.
    private function _cell(
        label as String,
        text as String,
        color as Number
    ) as [String, Array<DrawUtil.ValueRun>] {
        return (
            [label, DrawUtil.plainRuns(text, color)] as
            [String, Array<DrawUtil.ValueRun>]
        );
    }

    // Grid cell whose value has a trailing code-drawn degree glyph, optionally followed by more text.
    private function _degreeCell(
        label as String,
        text as String,
        color as Number,
        suffix as String
    ) as [String, Array<DrawUtil.ValueRun>] {
        return (
            [label, [[text, color, :degree, suffix] as DrawUtil.ValueRun]] as
            [String, Array<DrawUtil.ValueRun>]
        );
    }

    // Pairs both cells if both exist; otherwise adds whichever one exists as its own row; otherwise adds nothing.
    private function _gridRow(
        rows as Array<Array<[String, Array<DrawUtil.ValueRun>]> >,
        cellA as [String, Array<DrawUtil.ValueRun>]?,
        cellB as [String, Array<DrawUtil.ValueRun>]?
    ) as Void {
        if (cellA != null && cellB != null) {
            rows.add([
                cellA as [String, Array<DrawUtil.ValueRun>],
                cellB as [String, Array<DrawUtil.ValueRun>],
            ]);
        } else if (cellA != null) {
            rows.add([cellA as [String, Array<DrawUtil.ValueRun>]]);
        } else if (cellB != null) {
            rows.add([cellB as [String, Array<DrawUtil.ValueRun>]]);
        }
    }

    // A group that added no rows (all its fields were absent) doesn't get a boundary marker.
    private function _markGroupIfNonEmpty(
        rows as Array<Array<[String, Array<DrawUtil.ValueRun>]> >,
        groupBoundaries as Array<Number>,
        start as Number
    ) as Void {
        if (rows.size() > start) {
            groupBoundaries.add(start);
        }
    }

    // Everything the compact panel leaves out, for AircraftDetailView's scrollable grid.
    // Curated: long identity text (type/operator) gets its own row; only short/similar stats share a row.
    // Colors match the compact panel (alt=blue, speed=yellow, hdg=cyan, emergency=red); grey uses COLOR_DETAIL_VALUE here.
    private function _buildFullDetailRows(
        ac as Aircraft
    ) as
        [
            Array<Array<[String, Array<DrawUtil.ValueRun>]> >,
            Number,
            Number,
            Array<Boolean>,
        ]
    {
        var rows = [] as Array<Array<[String, Array<DrawUtil.ValueRun>]> >;
        // Row indices where a new visual group begins - converted to a per-row Boolean array at the end.
        var groupBoundaries = [] as Array<Number>;

        var identityStart = rows.size();
        var regCell =
            ac.registration != null
                ? _cell(
                      "Registration",
                      ac.registration as String,
                      COLOR_IDENTITY
                  )
                : null;
        _gridRow(rows, regCell, _cell("Hex", ac.hex, COLOR_IDENTITY));

        var typeStr = ac.typeDesc != null ? ac.typeDesc : ac.typeCode;
        var typeCell =
            typeStr != null
                ? _cell("Type", typeStr as String, COLOR_IDENTITY)
                : null;
        var categoryCell =
            ac.category != null
                ? _cell("Category", ac.category as String, COLOR_IDENTITY)
                : null;
        _gridRow(rows, typeCell, categoryCell);

        if (ac.operatorName != null) {
            rows.add([
                _cell("Operator", ac.operatorName as String, COLOR_IDENTITY),
            ]);
        }
        _markGroupIfNonEmpty(rows, groupBoundaries, identityStart);

        var performanceStart = rows.size();
        var altCell = null as [String, Array<DrawUtil.ValueRun>]?;
        if (ac.onGround) {
            altCell = _cell("Altitude", "GND", COLOR_ALT);
        } else if (ac.altBaro != null) {
            altCell = _cell(
                "Altitude",
                _formatAltitude(ac.altBaro as Number),
                COLOR_ALT
            );
        }
        var vertRateCell = null as [String, Array<DrawUtil.ValueRun>]?;
        if (ac.vertRate != null) {
            var vr = ac.vertRate as Float;
            var climbing = vr > 0;
            var sign = climbing ? "+" : "";
            vertRateCell = _cell(
                "Vertical Rate",
                sign + _formatVertRate(_round(vr)),
                climbing ? COLOR_SUCCESS : COLOR_WARN
            );
        }
        _gridRow(rows, altCell, vertRateCell);

        var gsCell =
            ac.gs != null
                ? _cell(
                      "Ground Speed",
                      _formatSpeedKt(_round(ac.gs as Float)),
                      COLOR_SPEED
                  )
                : null;
        var iasCell =
            ac.ias != null
                ? _cell("IAS", _formatSpeedKt(ac.ias as Number), COLOR_SPEED)
                : null;
        _gridRow(rows, gsCell, iasCell);

        var tasCell =
            ac.tas != null
                ? _cell(
                      "TAS",
                      _formatSpeedKt(_round(ac.tas as Float)),
                      COLOR_SPEED
                  )
                : null;
        var machCell =
            ac.mach != null
                ? _cell("Mach", (ac.mach as Float).format("%.2f"), COLOR_SPEED)
                : null;
        _gridRow(rows, tasCell, machCell);
        _markGroupIfNonEmpty(rows, groupBoundaries, performanceStart);

        var navStatusStart = rows.size();
        var emergency = ac.isEmergency();
        var hdgCell =
            ac.heading != null
                ? _degreeCell(
                      "Heading",
                      _roundHeading(ac.heading as Float).toString(),
                      COLOR_HDG,
                      ""
                  )
                : null;
        var squawkCell = null as [String, Array<DrawUtil.ValueRun>]?;
        if (ac.squawk != null || emergency) {
            var squawkColor = emergency ? COLOR_EMERGENCY : COLOR_SQUAWK;
            var squawkText = ac.squawk != null ? ac.squawk as String : "";
            // Full space before the icon, not DrawUtil's own small fixed gap.
            squawkCell = emergency
                ? [
                      "Squawk",
                      [
                          [squawkText + " ", squawkColor, :warning, ""] as
                              DrawUtil.ValueRun,
                      ],
                  ]
                : _cell("Squawk", squawkText, squawkColor);
        }
        _gridRow(rows, hdgCell, squawkCell);

        var statusParts = [] as Array<String>;
        if (ac.spi) {
            statusParts.add("IDENT");
        }
        if (ac.alertFlag) {
            statusParts.add("ALERT");
        }
        if (statusParts.size() > 0) {
            rows.add([
                _cell(
                    "Status",
                    _join(statusParts, " "),
                    emergency ? COLOR_EMERGENCY : COLOR_WARN
                ),
            ]);
        }
        _markGroupIfNonEmpty(rows, groupBoundaries, navStatusStart);

        var targetStart = rows.size();
        var selAltCell =
            ac.navAltitude != null
                ? _cell(
                      "Selected Alt",
                      _formatAltitude(ac.navAltitude as Number),
                      COLOR_DETAIL_VALUE
                  )
                : null;
        var selHdgCell =
            ac.navHeading != null
                ? _degreeCell(
                      "Selected Hdg",
                      _roundHeading(ac.navHeading as Float).toString(),
                      COLOR_DETAIL_VALUE,
                      ""
                  )
                : null;
        _gridRow(rows, selAltCell, selHdgCell);
        _markGroupIfNonEmpty(rows, groupBoundaries, targetStart);

        var envStart = rows.size();
        if (ac.windDir != null && ac.windSpeed != null) {
            rows.add([
                _degreeCell(
                    "Wind",
                    (ac.windDir as Number).toString(),
                    COLOR_ENV,
                    " @ " + _formatSpeedKt(ac.windSpeed as Number)
                ),
            ]);
        }

        var outTempCell =
            ac.outsideAirTemp != null
                ? _degreeCell(
                      "Outside Temp",
                      (ac.outsideAirTemp as Number).toString(),
                      COLOR_ENV,
                      "C"
                  )
                : null;
        var totalTempCell =
            ac.totalAirTemp != null
                ? _degreeCell(
                      "Total Air Temp",
                      (ac.totalAirTemp as Number).toString(),
                      COLOR_ENV,
                      "C"
                  )
                : null;
        _gridRow(rows, outTempCell, totalTempCell);
        _markGroupIfNonEmpty(rows, groupBoundaries, envStart);

        // Separate rows, not one joined "dep -> arr" line - a full description is too long for one line.
        var routeStart = rows.size();
        rows.add([_cell("Departure", "Loading...", COLOR_ROUTE_DIM)]);
        var depIndex = rows.size() - 1;
        rows.add([_cell("Arrival", "Loading...", COLOR_ROUTE_DIM)]);
        var arrIndex = rows.size() - 1;
        _markGroupIfNonEmpty(rows, groupBoundaries, routeStart);

        var groupStarts = [] as Array<Boolean>;
        for (var i = 0; i < rows.size(); i++) {
            groupStarts.add(false);
        }
        for (var i = 0; i < groupBoundaries.size(); i++) {
            groupStarts[groupBoundaries[i] as Number] = true;
        }

        return (
            [rows, depIndex, arrIndex, groupStarts] as
            [
                Array<Array<[String, Array<DrawUtil.ValueRun>]> >,
                Number,
                Number,
                Array<Boolean>,
            ]
        );
    }

    private function _join(parts as Array<String>, sep as String) as String {
        var out = "";
        for (var i = 0; i < parts.size(); i++) {
            out += i == 0 ? parts[i] : sep + parts[i];
        }
        return out;
    }

    private function _formatKm(km as Float) as String {
        var whole = _round(km);
        if (km >= 10.0 || (km - whole).abs() < 0.05) {
            return whole.toString() + "km";
        }
        return km.format("%.1f") + "km";
    }

    private function _formatAltitude(altFt as Number) as String {
        if (Settings.useMetricUnits) {
            return _round(altFt.toFloat() * 0.3048).toString() + "m";
        }
        return altFt.toString() + "ft";
    }

    private function _formatSpeedKt(kt as Number) as String {
        if (Settings.useMetricUnits) {
            return _round(kt.toFloat() * 1.852).toString() + "km/h";
        }
        return kt.toString() + "kt";
    }

    // Caller keeps the leading "+"/sign, this only formats the magnitude+unit.
    private function _formatVertRate(fpm as Number) as String {
        if (Settings.useMetricUnits) {
            return _round(fpm.toFloat() * 0.3048).toString() + "m/min";
        }
        return fpm.toString() + "fpm";
    }
}
