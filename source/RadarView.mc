import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

const APP_VERSION = "0.6.3";

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
    private const COLOR_RING = GRAYS[4];
    private const COLOR_RING_ALPHA = DrawUtil.ALPHA_25;
    private const COLOR_BOUNDARY_ALPHA = DrawUtil.ALPHA_50;
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

    private var _centerLat as Float?;
    private var _centerLon as Float?;
    private var _hasFix as Boolean = false;

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
    // Display-only, doesn't clear _fetchInFlight or cancel anything - cancelAllRequests() crashed on real hardware.
    private var _fetchTimedOutDisplay as Boolean = false;
    private const FETCH_TIMEOUT_MS = 10000;
    private var _lastDrawnPositions as Array<[String, Number, Number]> = [];
    // [hex, x0, y0, x1, y1] - hex-tagged so a label may overlap its own icon/chevron/reticle, only another's clips.
    private var _reservedRects as
        Array<[String, Number, Number, Number, Number]> = [];
    // hex -> [category, shapeKey, sizeScale, iconHalfExtent] - cleared whenever aircraft
    // data changes (_onFetchResult), not every redraw - see _classify().
    private var _classifyCache as
        Dictionary<String, [String, String, Float, Number]> = {};

    private var _selectedHex as String?;
    // [lat, lon, altitudeFt, onGround] - altitude/ground drive the trail's gradient/dashed rendering.
    private var _selectedTrack as Array<[Float, Float, Number, Boolean]> = [];
    private var _trackFetchInFlight as Boolean = false;
    private var _trackFetchHex as String?;
    private var _trackHasHistory as Boolean = false;
    private var _selectedMissCount as Number = 0;
    private var _trackFetchRetried as Boolean = false;
    // Last confirmed position of the selected aircraft - frozen-camera fallback on auto-deselect, see _onFetchResult.
    private var _selectedLastPos as [Float, Float]?;

    // The pushed full-detail view, null when closed - route-fetch results only apply while this is still open.
    private var _detailView as AircraftDetailView?;
    private var _routeFetchInFlight as Boolean = false;
    private var _routeFetchHex as String?;
    private var _routeFetchRetried as Boolean = false;
    // Departure/arrival airport-info lookups - independent of the route fetch and of each other.
    private var _airportFetchHex as String?;
    private var _pendingDepIcao as String?;
    private var _pendingArrIcao as String?;

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
    // Caps continueDrag's redraw rate - unthrottled, it called requestUpdate on every raw mouse-move event.
    private var _lastDragRedrawMs as Number = 0;
    private const DRAG_REDRAW_INTERVAL_MS = 33;

    private var _pollTimer as Timer.Timer?;
    private var _ticksSincePoll as Number = 0;
    // Drives the fetch spinner's orbit animation, without redrawing so often it hurts battery.
    private const ANIM_TICK_MS = 200;
    // The screen going dark (wrist down) doesn't hide this view - _onTick keeps polling for nobody unless told.
    private var _displayOff as Boolean = false;

    // Both piggyback on _onTick's existing cadence, not their own Timer - a second resident Timer
    // already crashed this app once with "Too Many Timers Error" (see [[connectiq_gotchas]]).
    private var _zoomChangedAtMs as Number?;
    // Not lower - _onTick's own cadence (ANIM_TICK_MS) is the real floor on how fast this can fire.
    private const ZOOM_DEBOUNCE_MS = ANIM_TICK_MS;
    private var _nextRetryAtMs as Number?;
    private var _retryBackoffMs as Number = INITIAL_RETRY_BACKOFF_MS;
    private const INITIAL_RETRY_BACKOFF_MS = 2000;
    private const MAX_RETRY_BACKOFF_MS = 30000;

    private var _noGpsText as String = "";
    private var _noSignalText as String = "";
    private var _tooBusyText as String = "";
    private var _fetchingText as String = "";
    private var _liveText as String = "";
    private var _fontSmall as Graphics.FontType = Graphics.FONT_SMALL;
    private var _fontTiny as Graphics.FontType = Graphics.FONT_XTINY;
    private var _client as AirplanesLiveClient = new AirplanesLiveClient();
    private var _openSky as OpenSkyClient = new OpenSkyClient();
    private var _routeClient as RouteClient = new RouteClient();
    private var _airportClient as AirportClient = new AirportClient();

    // One bitmap per shape - emergency halo is drawn via an offset-blit outline, not a second dilated variant.
    private var _iconBitmaps as Dictionary<String, Graphics.BitmapType> = {};

    public function initialize() {
        View.initialize();
    }

    public function onLayout(dc as Dc) as Void {
        _noGpsText = WatchUi.loadResource(Rez.Strings.NoGps) as String;
        _noSignalText = WatchUi.loadResource(Rez.Strings.NoSignal) as String;
        _tooBusyText = WatchUi.loadResource(Rez.Strings.TooBusy) as String;
        _fetchingText = WatchUi.loadResource(Rez.Strings.Fetching) as String;
        _liveText = WatchUi.loadResource(Rez.Strings.Fetched) as String;
        _fontSmall =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_SMALL) as
            Graphics.FontDefinition;
        _fontTiny =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_TINY) as
            Graphics.FontDefinition;
        _iconBitmaps = {
            "a10" => WatchUi.loadResource(Rez.Drawables.AircraftA10) as
            Graphics.BitmapType,
            "a225" => WatchUi.loadResource(Rez.Drawables.AircraftA225) as
            Graphics.BitmapType,
            "a319" => WatchUi.loadResource(Rez.Drawables.AircraftA319) as
            Graphics.BitmapType,
            "a320" => WatchUi.loadResource(Rez.Drawables.AircraftA320) as
            Graphics.BitmapType,
            "a321" => WatchUi.loadResource(Rez.Drawables.AircraftA321) as
            Graphics.BitmapType,
            "a332" => WatchUi.loadResource(Rez.Drawables.AircraftA332) as
            Graphics.BitmapType,
            "a359" => WatchUi.loadResource(Rez.Drawables.AircraftA359) as
            Graphics.BitmapType,
            "a380" => WatchUi.loadResource(Rez.Drawables.AircraftA380) as
            Graphics.BitmapType,
            "a400" => WatchUi.loadResource(Rez.Drawables.AircraftA400) as
            Graphics.BitmapType,
            "airliner" => WatchUi.loadResource(
                Rez.Drawables.AircraftAirliner
            ) as Graphics.BitmapType,
            "alpha_jet" => WatchUi.loadResource(
                Rez.Drawables.AircraftAlphaJet
            ) as Graphics.BitmapType,
            "apache" => WatchUi.loadResource(Rez.Drawables.AircraftApache) as
            Graphics.BitmapType,
            "b1b_lancer" => WatchUi.loadResource(
                Rez.Drawables.AircraftB1bLancer
            ) as Graphics.BitmapType,
            "b52" => WatchUi.loadResource(Rez.Drawables.AircraftB52) as
            Graphics.BitmapType,
            "b707" => WatchUi.loadResource(Rez.Drawables.AircraftB707) as
            Graphics.BitmapType,
            "b737" => WatchUi.loadResource(Rez.Drawables.AircraftB737) as
            Graphics.BitmapType,
            "b738" => WatchUi.loadResource(Rez.Drawables.AircraftB738) as
            Graphics.BitmapType,
            "b739" => WatchUi.loadResource(Rez.Drawables.AircraftB739) as
            Graphics.BitmapType,
            "bae_hawk" => WatchUi.loadResource(Rez.Drawables.AircraftBaeHawk) as
            Graphics.BitmapType,
            "balloon" => WatchUi.loadResource(Rez.Drawables.AircraftBalloon) as
            Graphics.BitmapType,
            "beluga" => WatchUi.loadResource(Rez.Drawables.AircraftBeluga) as
            Graphics.BitmapType,
            "blackhawk" => WatchUi.loadResource(
                Rez.Drawables.AircraftBlackhawk
            ) as Graphics.BitmapType,
            "blimp" => WatchUi.loadResource(Rez.Drawables.AircraftBlimp) as
            Graphics.BitmapType,
            "c130" => WatchUi.loadResource(Rez.Drawables.AircraftC130) as
            Graphics.BitmapType,
            "c17" => WatchUi.loadResource(Rez.Drawables.AircraftC17) as
            Graphics.BitmapType,
            "c2" => WatchUi.loadResource(Rez.Drawables.AircraftC2) as
            Graphics.BitmapType,
            "c5" => WatchUi.loadResource(Rez.Drawables.AircraftC5) as
            Graphics.BitmapType,
            "cessna" => WatchUi.loadResource(Rez.Drawables.AircraftCessna) as
            Graphics.BitmapType,
            "chinook" => WatchUi.loadResource(Rez.Drawables.AircraftChinook) as
            Graphics.BitmapType,
            "cirrus_sr22" => WatchUi.loadResource(
                Rez.Drawables.AircraftCirrusSr22
            ) as Graphics.BitmapType,
            "dauphin" => WatchUi.loadResource(Rez.Drawables.AircraftDauphin) as
            Graphics.BitmapType,
            "e390" => WatchUi.loadResource(Rez.Drawables.AircraftE390) as
            Graphics.BitmapType,
            "e3awacs" => WatchUi.loadResource(Rez.Drawables.AircraftE3awacs) as
            Graphics.BitmapType,
            "e737" => WatchUi.loadResource(Rez.Drawables.AircraftE737) as
            Graphics.BitmapType,
            "f18" => WatchUi.loadResource(Rez.Drawables.AircraftF18) as
            Graphics.BitmapType,
            "f35" => WatchUi.loadResource(Rez.Drawables.AircraftF35) as
            Graphics.BitmapType,
            "f5_tiger" => WatchUi.loadResource(Rez.Drawables.AircraftF5Tiger) as
            Graphics.BitmapType,
            "gazelle" => WatchUi.loadResource(Rez.Drawables.AircraftGazelle) as
            Graphics.BitmapType,
            "glider" => WatchUi.loadResource(Rez.Drawables.AircraftGlider) as
            Graphics.BitmapType,
            "ground_emergency" => WatchUi.loadResource(
                Rez.Drawables.AircraftGroundEmergency
            ) as Graphics.BitmapType,
            "ground_service" => WatchUi.loadResource(
                Rez.Drawables.AircraftGroundService
            ) as Graphics.BitmapType,
            "ground_tower" => WatchUi.loadResource(
                Rez.Drawables.AircraftGroundTower
            ) as Graphics.BitmapType,
            "ground_unknown" => WatchUi.loadResource(
                Rez.Drawables.AircraftGroundUnknown
            ) as Graphics.BitmapType,
            "gyrocopter" => WatchUi.loadResource(
                Rez.Drawables.AircraftGyrocopter
            ) as Graphics.BitmapType,
            "heavy_2e" => WatchUi.loadResource(Rez.Drawables.AircraftHeavy2e) as
            Graphics.BitmapType,
            "heavy_4e" => WatchUi.loadResource(Rez.Drawables.AircraftHeavy4e) as
            Graphics.BitmapType,
            "helicopter" => WatchUi.loadResource(
                Rez.Drawables.AircraftHelicopter
            ) as Graphics.BitmapType,
            "hi_perf" => WatchUi.loadResource(Rez.Drawables.AircraftHiPerf) as
            Graphics.BitmapType,
            "hunter" => WatchUi.loadResource(Rez.Drawables.AircraftHunter) as
            Graphics.BitmapType,
            "il_62" => WatchUi.loadResource(Rez.Drawables.AircraftIl62) as
            Graphics.BitmapType,
            "jet_nonswept" => WatchUi.loadResource(
                Rez.Drawables.AircraftJetNonswept
            ) as Graphics.BitmapType,
            "jet_swept" => WatchUi.loadResource(
                Rez.Drawables.AircraftJetSwept
            ) as Graphics.BitmapType,
            "l159" => WatchUi.loadResource(Rez.Drawables.AircraftL159) as
            Graphics.BitmapType,
            "lancaster" => WatchUi.loadResource(
                Rez.Drawables.AircraftLancaster
            ) as Graphics.BitmapType,
            "m326" => WatchUi.loadResource(Rez.Drawables.AircraftM326) as
            Graphics.BitmapType,
            "md11" => WatchUi.loadResource(Rez.Drawables.AircraftMd11) as
            Graphics.BitmapType,
            "md_a4" => WatchUi.loadResource(Rez.Drawables.AircraftMdA4) as
            Graphics.BitmapType,
            "md_f15" => WatchUi.loadResource(Rez.Drawables.AircraftMdF15) as
            Graphics.BitmapType,
            "mil24" => WatchUi.loadResource(Rez.Drawables.AircraftMil24) as
            Graphics.BitmapType,
            "mirage" => WatchUi.loadResource(Rez.Drawables.AircraftMirage) as
            Graphics.BitmapType,
            "miragef1" => WatchUi.loadResource(
                Rez.Drawables.AircraftMiragef1
            ) as Graphics.BitmapType,
            "p3_orion" => WatchUi.loadResource(Rez.Drawables.AircraftP3Orion) as
            Graphics.BitmapType,
            "p8" => WatchUi.loadResource(Rez.Drawables.AircraftP8) as
            Graphics.BitmapType,
            "pa24" => WatchUi.loadResource(Rez.Drawables.AircraftPa24) as
            Graphics.BitmapType,
            "para" => WatchUi.loadResource(Rez.Drawables.AircraftPara) as
            Graphics.BitmapType,
            "puma" => WatchUi.loadResource(Rez.Drawables.AircraftPuma) as
            Graphics.BitmapType,
            "rafale" => WatchUi.loadResource(Rez.Drawables.AircraftRafale) as
            Graphics.BitmapType,
            "rutan_veze" => WatchUi.loadResource(
                Rez.Drawables.AircraftRutanVeze
            ) as Graphics.BitmapType,
            "s61" => WatchUi.loadResource(Rez.Drawables.AircraftS61) as
            Graphics.BitmapType,
            "sb39" => WatchUi.loadResource(Rez.Drawables.AircraftSb39) as
            Graphics.BitmapType,
            "strato" => WatchUi.loadResource(Rez.Drawables.AircraftStrato) as
            Graphics.BitmapType,
            "super_guppy" => WatchUi.loadResource(
                Rez.Drawables.AircraftSuperGuppy
            ) as Graphics.BitmapType,
            "t38" => WatchUi.loadResource(Rez.Drawables.AircraftT38) as
            Graphics.BitmapType,
            "tiger" => WatchUi.loadResource(Rez.Drawables.AircraftTiger) as
            Graphics.BitmapType,
            "tornado" => WatchUi.loadResource(Rez.Drawables.AircraftTornado) as
            Graphics.BitmapType,
            "twin_large" => WatchUi.loadResource(
                Rez.Drawables.AircraftTwinLarge
            ) as Graphics.BitmapType,
            "typhoon" => WatchUi.loadResource(Rez.Drawables.AircraftTyphoon) as
            Graphics.BitmapType,
            "u2" => WatchUi.loadResource(Rez.Drawables.AircraftU2) as
            Graphics.BitmapType,
            "uav" => WatchUi.loadResource(Rez.Drawables.AircraftUav) as
            Graphics.BitmapType,
            "unknown" => WatchUi.loadResource(Rez.Drawables.AircraftUnknown) as
            Graphics.BitmapType,
            "v22_fast" => WatchUi.loadResource(Rez.Drawables.AircraftV22Fast) as
            Graphics.BitmapType,
            "v22_slow" => WatchUi.loadResource(Rez.Drawables.AircraftV22Slow) as
            Graphics.BitmapType,
            "verhees" => WatchUi.loadResource(Rez.Drawables.AircraftVerhees) as
            Graphics.BitmapType,
            "wb57" => WatchUi.loadResource(Rez.Drawables.AircraftWb57) as
            Graphics.BitmapType,
        };

        var charSize = DrawUtil.measureChar(dc, _fontTiny);
        _charW = charSize[0];
        _charH = charSize[1];
        // Sized to fit the button hints with a visible gap on both sides - see BUTTON_HINT_REACH_PX.
        _edgeMargin = (BUTTON_HINT_REACH_PX + CENTER_BIAS_PX) * 2;
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
        var timer = new Timer.Timer();
        timer.start(method(:_onTick), ANIM_TICK_MS, true);
        _pollTimer = timer;
        _ticksSincePoll = 0;

        _fetchNow();
    }

    public function onHide() as Void {
        if (_pollTimer != null) {
            (_pollTimer as Timer.Timer).stop();
            _pollTimer = null;
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

    public function _onTick() as Void {
        if (_displayOff) {
            return;
        }

        var startedAt = _fetchStartMs;
        if (
            _fetchInFlight &&
            !_fetchTimedOutDisplay &&
            startedAt != null &&
            System.getTimer() - (startedAt as Number) > FETCH_TIMEOUT_MS
        ) {
            _fetchTimedOutDisplay = true;
            WatchUi.requestUpdate();
        }

        var now = System.getTimer();

        // Debounced: a burst of zoom taps only fetches once, shortly after the last one.
        var changedAt = _zoomChangedAtMs;
        if (
            changedAt != null &&
            now - (changedAt as Number) >= ZOOM_DEBOUNCE_MS
        ) {
            _zoomChangedAtMs = null;
            _fetchNow();
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
            var pollMs = POLL_MS_BY_ZOOM[Settings.zoomIndex];
            if (Settings.batterySaverMode) {
                pollMs *= BATTERY_SAVER_MULTIPLIER;
            }
            if (_ticksSincePoll * ANIM_TICK_MS >= pollMs) {
                _ticksSincePoll = 0;
                _fetchNow();
            }
        }

        if (_fetchInFlight && !_fetchTimedOutDisplay) {
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

        // Drop this raw event if it's arriving too soon - _dragLastCoords stays at the last processed point.
        var now = System.getTimer();
        if (now - _lastDragRedrawMs < DRAG_REDRAW_INTERVAL_MS) {
            return;
        }
        _lastDragRedrawMs = now;

        _applyDragDelta(x, y);
        WatchUi.requestUpdate();
    }

    // Shared by continueDrag and endDrag, so a release inside a throttled window doesn't lose motion.
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
        _manualFocus = null;
        var ac = _aircraftByHex[hex];
        _selectedLastPos = ac != null ? [ac.lat, ac.lon] : null;
        _fetchSelectedTrack();
        WatchUi.requestUpdate();
    }

    public function deselectAircraft() as Void {
        _selectedHex = null;
        _selectedTrack = [];
        _selectedMissCount = 0;
        _selectedLastPos = null;
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
    }

    private function _fetchSelectedRoute() as Void {
        var hex = _selectedHex;
        if (hex == null || _routeFetchInFlight) {
            return;
        }
        _routeFetchInFlight = true;
        _routeFetchHex = hex;
        var ac = _selectedAircraft();
        var callsign = ac != null ? (ac as Aircraft).flight : null;
        if (callsign == null) {
            // No callsign to look up by - same "no route found" outcome as a 404.
            _onRouteResult(null, null, true);
            return;
        }
        _routeClient.fetchRoute(callsign as String, method(:_onRouteResult));
    }

    public function _onRouteResult(
        dep as String?,
        arr as String?,
        ok as Boolean
    ) as Void {
        _routeFetchInFlight = false;
        var fetchedHex = _routeFetchHex;
        _routeFetchHex = null;

        var view = _detailView;
        if (view == null) {
            return;
        }
        var stillRelevant =
            fetchedHex != null &&
            _selectedHex != null &&
            (fetchedHex as String).equals(_selectedHex as String);
        if (!stillRelevant) {
            // Reopened for a different aircraft mid-fetch - retry for what's actually showing.
            _fetchSelectedRoute();
            return;
        }

        if (ok) {
            _routeFetchRetried = false;
            _airportFetchHex = fetchedHex;
            _pendingDepIcao = dep;
            _pendingArrIcao = arr;
            if (dep != null) {
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
        var stillRelevant =
            _airportFetchHex != null &&
            _selectedHex != null &&
            (_airportFetchHex as String).equals(_selectedHex as String);
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
        suppressInputBriefly();
    }

    private function _fetchSelectedTrack() as Void {
        var hex = _selectedHex;
        if (hex == null || _trackFetchInFlight) {
            return;
        }
        _trackFetchInFlight = true;
        _trackFetchHex = hex;
        _openSky.fetchTrack(hex as String, method(:_onTrackResult));
    }

    public function _onTrackResult(
        points as Array<[Float, Float, Number, Boolean]>,
        ok as Boolean
    ) as Void {
        _trackFetchInFlight = false;
        var fetchedHex = _trackFetchHex;
        _trackFetchHex = null;

        var stillSelected =
            fetchedHex != null &&
            _selectedHex != null &&
            (fetchedHex as String).equals(_selectedHex as String);

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

    private function _fetchNow() as Void {
        if (_fetchInFlight) {
            _refetchPending = true;
            return;
        }
        if (!_hasFix or _centerLat == null or _centerLon == null) {
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
        _fetchTimedOutDisplay = false;
        _lastFetchOk = ok;
        _lastFetchTooMuchData = tooMuchData;

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

        if (_refetchPending) {
            _ticksSincePoll = 0;
            _fetchNow();
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
        var topPanelH = _topPanelHeight();

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
        var bottomPanelH =
            selected != null ? _detailPanelHeight(selected as Aircraft) : 0;

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
            _drawDetailPanel(dc, cx, cy, h, radiusPx, selected as Aircraft);
        }

        _drawTopPanel(dc, cx, cy, radiusPx);

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
        var x = cx + (ringPx * Math.sin(theta)).toNumber();
        var y = cy - (ringPx * Math.cos(theta)).toNumber();
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
        dc.drawLine(
            cx + (radiusPx * sinT).toNumber(),
            cy - (radiusPx * cosT).toNumber(),
            cx + ((radiusPx - tickLen) * sinT).toNumber(),
            cy - ((radiusPx - tickLen) * cosT).toNumber()
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
        var ringR = (radiusPx + trueEdge) / 2 + CENTER_BIAS_PX;

        var plusPos = _buttonHintPos(cx, cy, ringR, 270.0);
        var minusPos = _buttonHintPos(cx, cy, ringR, 240.0);
        var menuPos = _buttonHintPos(cx, cy, ringR, 60.0);
        var recenterPos = _buttonHintPos(cx, cy, ringR, 120.0);

        _drawPlusHint(dc, plusPos[0], plusPos[1]);
        _drawMinusHint(dc, minusPos[0], minusPos[1]);
        _drawMenuHint(dc, menuPos[0], menuPos[1]);
        _drawRecenterHint(dc, recenterPos[0], recenterPos[1]);
    }

    // Coordinate math truncates toward zero, which biases icons slightly inward without this.
    private const CENTER_BIAS_PX = 1;

    // Farthest a hint icon's own drawn pixels reach from its center - hints aren't rotated to the ring's
    // radial direction, so the worst case is the full diagonal of the largest icon (s=6 -> 6*sqrt(2) =~ 8.5px).
    private const BUTTON_HINT_REACH_PX = _charW;

    private function _buttonHintPos(
        cx as Number,
        cy as Number,
        ringR as Number,
        compassDeg as Float
    ) as [Number, Number] {
        var theta = Math.toRadians(compassDeg);
        var x = cx + (ringR * Math.sin(theta)).toNumber();
        var y = cy - (ringR * Math.cos(theta)).toNumber();
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
        if (_fetchTimedOutDisplay) {
            return [_noSignalText, Graphics.COLOR_RED];
        }
        if (!_lastFetchOk) {
            return _lastFetchTooMuchData
                ? [_tooBusyText, COLOR_WARN]
                : [_noSignalText, Graphics.COLOR_RED];
        }
        if (_fetchInFlight && !_viewHasFreshData) {
            return [_fetchingText, COLOR_GRID_LABEL];
        }
        return [_liveText, COLOR_SUCCESS];
    }

    private function _topPanelHeight() as Number {
        return _topPanelLines().size() * _topPanelLineHeight + 8;
    }

    private function _drawTopPanel(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number
    ) as Void {
        var lines = _topPanelLines();
        var panelH = lines.size() * _topPanelLineHeight + 8;

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

        if (_fetchInFlight && !_fetchTimedOutDisplay) {
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
        dc.fillCircle(
            x + (FETCH_SPINNER_R * Math.cos(theta)).toNumber(),
            y + (FETCH_SPINNER_R * Math.sin(theta)).toNumber(),
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
                    _drawDashedLine(dc, p0[0], p0[1], screen[0], screen[1]);
                } else {
                    dc.setStroke(
                        DrawUtil.withAlpha(trailColor, COLOR_TRAIL_ALPHA)
                    );
                    dc.drawLine(p0[0], p0[1], screen[0], screen[1]);
                }
            }
            prevScreen = screen;
            prevPt = pt;
        }
    }

    // No native dashed-stroke primitive - subdivides the segment into fixed-length dash/gap pairs.
    private function _drawDashedLine(
        dc as Dc,
        x0 as Number,
        y0 as Number,
        x1 as Number,
        y1 as Number
    ) as Void {
        var dx = (x1 - x0).toFloat();
        var dy = (y1 - y0).toFloat();
        var length = Math.sqrt(dx * dx + dy * dy);
        if (length < 1.0) {
            return;
        }
        var ux = dx / length;
        var uy = dy / length;
        var step = TRAIL_DASH_PX + TRAIL_GAP_PX;
        var pos = 0.0;
        for (var i = 0; i < TRAIL_MAX_DASHES_PER_SEGMENT; i++) {
            var dashEnd = pos + TRAIL_DASH_PX;
            if (dashEnd > length) {
                dashEnd = length;
            }
            dc.drawLine(
                (x0 + ux * pos).toNumber(),
                (y0 + uy * pos).toNumber(),
                (x0 + ux * dashEnd).toNumber(),
                (y0 + uy * dashEnd).toNumber()
            );
            pos += step;
            if (pos >= length) {
                break;
            }
        }
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
        return (
            [
                (x + r * EMERGENCY_BADGE_SIN).toNumber(),
                (y - r * EMERGENCY_BADGE_COS).toNumber(),
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

    private function _drawIconVariant(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        color as Number
    ) as Void {
        var shape = _shapeKeyForAircraft(ac);
        var track = ac.track;
        var theta =
            track != null && AircraftClassifier.shapeRotates(shape)
                ? Math.toRadians(track)
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

        dc.drawBitmap2(0, 0, _iconBitmaps[shape] as Graphics.BitmapType, {
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
        var cx = x + (r * Math.sin(theta)).toNumber();
        var cy = y - (r * Math.cos(theta)).toNumber();
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
        var lines = _buildLabelLines(ac, showCallsign, showSpeed, showAltitude);
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
        var x = cx - totalW / 2;
        for (var i = 0; i < segments.size(); i++) {
            DrawUtil.drawRun(dc, x, y, _fontTiny, segments[i]);
            x += (widths[i] as Number) + _segmentGapPx;
        }
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
                    _formatSpeedKt((ac.gs as Float).toNumber()),
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

    private function _drawDetailPanel(
        dc as Dc,
        cx as Number,
        cy as Number,
        h as Number,
        radiusPx as Number,
        ac as Aircraft
    ) as Void {
        var lines = _buildDetailLines(ac);
        if (lines.size() == 0) {
            return;
        }

        var panelH = lines.size() * _detailPanelLineHeight + 8;
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
        var lines = _buildDetailLines(ac);
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
        var widths = [] as Array<Number>;
        var totalW = -_segmentGapPx;
        for (var i = 0; i < segments.size(); i++) {
            var w = DrawUtil.runWidth(dc, _fontTiny, segments[i]);
            widths.add(w);
            totalW += w + _segmentGapPx;
        }

        var x = cx - totalW / 2;
        for (var i = 0; i < segments.size(); i++) {
            DrawUtil.drawRun(dc, x, y, _fontTiny, segments[i]);
            x += (widths[i] as Number) + _segmentGapPx;
        }
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
                    _formatSpeedKt((ac.gs as Float).toNumber()),
                    COLOR_SPEED
                )
            );
        }
        if (ac.track != null) {
            statSegs.add(
                [
                    (ac.track as Float).toNumber().toString(),
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
                sign + _formatVertRate(vr.toNumber()),
                climbing ? COLOR_SUCCESS : COLOR_WARN
            );
        }
        _gridRow(rows, altCell, vertRateCell);

        var gsCell =
            ac.gs != null
                ? _cell(
                      "Ground Speed",
                      _formatSpeedKt((ac.gs as Float).toNumber()),
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
                      _formatSpeedKt((ac.tas as Float).toNumber()),
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
            ac.track != null
                ? _degreeCell(
                      "Heading",
                      (ac.track as Float).toNumber().toString(),
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
                      (ac.navHeading as Float).toNumber().toString(),
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
        var whole = km.toNumber();
        if (km >= 10.0 || (km - whole).abs() < 0.05) {
            return whole.toString() + "km";
        }
        return km.format("%.1f") + "km";
    }

    private function _formatAltitude(altFt as Number) as String {
        if (Settings.useMetricUnits) {
            return (altFt.toFloat() * 0.3048).toNumber().toString() + "m";
        }
        return altFt.toString() + "ft";
    }

    private function _formatSpeedKt(kt as Number) as String {
        if (Settings.useMetricUnits) {
            return (kt.toFloat() * 1.852).toNumber().toString() + "km/h";
        }
        return kt.toString() + "kt";
    }

    // Caller keeps the leading "+"/sign, this only formats the magnitude+unit.
    private function _formatVertRate(fpm as Number) as String {
        if (Settings.useMetricUnits) {
            return (fpm.toFloat() * 0.3048).toNumber().toString() + "m/min";
        }
        return fpm.toString() + "fpm";
    }
}
