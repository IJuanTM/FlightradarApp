import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

class RadarView extends WatchUi.View {
    // Indexed alongside Settings.ZOOM_LEVELS_KM - slower at wide zoom, where a big response is also most likely to hit the platform's transport-size ceiling.
    private const POLL_MS_BY_ZOOM as Array<Number> = [1000, 1000, 2000, 3000];
    // Applied on top of POLL_MS_BY_ZOOM when Settings.batterySaverMode is on - fewer network fetches, not a different zoom-based schedule.
    private const BATTERY_SAVER_MULTIPLIER = 3;
    // Tolerates a transient ADS-B reception gap for the selected aircraft before giving up on it.
    private const MAX_SELECTED_MISSES = 3;
    // 4 gives a consistent 1/2/3/4, 2/4/6/8, 5/10/15/20, 10/20/30/40 progression - a divisor of 3 gave an ugly 3/6/9 at 10km.
    private const RING_TARGET_COUNT = 4;
    private const EDGE_MARGIN = 20;
    // Wider than the icon - real taps land less precisely than a mouse click.
    private const HIT_RADIUS_PX = 24;
    private const DRAG_THRESHOLD_PX = 32;
    // Only bounds ongoing growth, never the initial OpenSky history.
    private const MAX_SELECTED_TRACK_POINTS = 500;

    // Same shade steps as ../TerminalWatchface's GRAYS, extended with two lighter steps for this app's own use.
    private const GRAYS =
        [0x111111, 0x333333, 0x555555, 0x777777, 0xaaaaaa, 0xcccccc] as
        Array<Number>;
    private const COLOR_RING = GRAYS[4];
    private const COLOR_RING_ALPHA = 0x28;
    private const COLOR_BOUNDARY_ALPHA = 0x40;
    private const COLOR_TICK_ALPHA = 0x50;
    private const COLOR_MINOR_TICK_ALPHA = 0x30;
    private const COLOR_GRID = GRAYS[3];
    private const COLOR_GRID_ALPHA = 0x10;
    private const COLOR_GRID_LABEL = GRAYS[2];
    private const GRID_LABEL_INSET = 22;
    private const TOP_PANEL_LINE_HEIGHT = 18;
    private const DETAIL_PANEL_LINE_HEIGHT = 18;
    private const COLOR_TRAIL_ALPHA = 0x90;
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

    // Full-detail "grey" values are white, not grey - both label and value read as the same dim tone otherwise. COLOR_ROUTE_DIM (same dim grey as the compact panel's "No Track History") is only for the Route field's loading/unknown/failed states, to read as "not resolved" rather than a plain fact.
    private const COLOR_DETAIL_VALUE = COLORS[0]; // white
    private const COLOR_ROUTE_DIM = COLOR_GRID_LABEL;

    // Detail panel value colors - not tied to aircraft category, just distinguishing fields at a glance.
    private const COLOR_ALT = COLORS[6]; // blue
    private const COLOR_SPEED = COLORS[3]; // yellow
    private const COLOR_HDG = COLORS[2]; // cyan
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
    private var _fetchInFlight as Boolean = false;
    private var _fetchStartMs as Number?;
    // Display-only, doesn't clear _fetchInFlight or cancel anything - cancelAllRequests() crashed on real hardware.
    private var _fetchTimedOutDisplay as Boolean = false;
    private const FETCH_TIMEOUT_MS = 10000;
    private var _lastDrawnPositions as Array<[String, Number, Number]> = [];
    // [hex, x0, y0, x1, y1] - hex-tagged so a label can freely overlap its own icon/chevron/reticle, only another aircraft's is a real clip.
    private var _reservedRects as
        Array<[String, Number, Number, Number, Number]> = [];

    private var _selectedHex as String?;
    // [lat, lon, altitudeFt, onGround] - altitude/ground drive the trail's gradient/dashed rendering.
    private var _selectedTrack as Array<[Float, Float, Number, Boolean]> = [];
    private var _trackFetchInFlight as Boolean = false;
    private var _trackFetchHex as String?;
    private var _trackHasHistory as Boolean = false;
    private var _selectedMissCount as Number = 0;
    private var _trackFetchRetried as Boolean = false;
    // Last confirmed position of the selected aircraft - the auto-deselect-on-miss path freezes the camera here, not via _focusPoint() (which falls through to the user's own position once the aircraft is already absent from _aircraftByHex, the exact state that path fires in).
    private var _selectedLastPos as [Float, Float]?;

    // The pushed full-detail view, null when closed - route-fetch results only apply while this is still open.
    private var _detailView as AircraftDetailView?;
    private var _routeFetchInFlight as Boolean = false;
    private var _routeFetchHex as String?;
    private var _routeFetchRetried as Boolean = false;

    private var _manualFocus as [Float, Float]?;
    private var _dragStartCoords as [Number, Number]?;
    private var _dragLastCoords as [Number, Number]?;
    private var _dragCommitted as Boolean = false;
    private var _lastRadiusPx as Number = 1;
    private var _lastScreenHeight as Number = 1;
    // Timestamp-gated, not a plain flag - a standalone tap may never fire beginDrag on real hardware.
    private var _dragStopAtMs as Number?;
    private const TAP_SUPPRESS_WINDOW_MS = 300;
    // Caps continueDrag's redraw rate - unthrottled, it called requestUpdate on every raw mouse-move event.
    private var _lastDragRedrawMs as Number = 0;
    private const DRAG_REDRAW_INTERVAL_MS = 33;

    private var _pollTimer as Timer.Timer?;
    private var _ticksSincePoll as Number = 0;
    // Drives the fetch spinner's orbit animation, without redrawing so often it hurts battery.
    private const ANIM_TICK_MS = 200;

    private var _noGpsText as String = "";
    private var _noSignalText as String = "";
    private var _tooBusyText as String = "";
    private var _fetchingText as String = "";
    private var _fetchedText as String = "";
    private var _fontSmall as Graphics.FontType = Graphics.FONT_SMALL;
    private var _fontTiny as Graphics.FontType = Graphics.FONT_XTINY;
    private var _client as AirplanesLiveClient = new AirplanesLiveClient();
    private var _openSky as OpenSkyClient = new OpenSkyClient();

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
        _fetchedText = WatchUi.loadResource(Rez.Strings.Fetched) as String;
        _fontSmall =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_SMALL) as
            Graphics.FontDefinition;
        _fontTiny =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_TINY) as
            Graphics.FontDefinition;
        _iconBitmaps = {
            "a10" => WatchUi.loadResource(Rez.Drawables.AircraftA10) as Graphics.BitmapType,
            "a225" => WatchUi.loadResource(Rez.Drawables.AircraftA225) as Graphics.BitmapType,
            "a319" => WatchUi.loadResource(Rez.Drawables.AircraftA319) as Graphics.BitmapType,
            "a320" => WatchUi.loadResource(Rez.Drawables.AircraftA320) as Graphics.BitmapType,
            "a321" => WatchUi.loadResource(Rez.Drawables.AircraftA321) as Graphics.BitmapType,
            "a332" => WatchUi.loadResource(Rez.Drawables.AircraftA332) as Graphics.BitmapType,
            "a359" => WatchUi.loadResource(Rez.Drawables.AircraftA359) as Graphics.BitmapType,
            "a380" => WatchUi.loadResource(Rez.Drawables.AircraftA380) as Graphics.BitmapType,
            "a400" => WatchUi.loadResource(Rez.Drawables.AircraftA400) as Graphics.BitmapType,
            "airliner" => WatchUi.loadResource(Rez.Drawables.AircraftAirliner) as Graphics.BitmapType,
            "alpha_jet" => WatchUi.loadResource(Rez.Drawables.AircraftAlphaJet) as Graphics.BitmapType,
            "apache" => WatchUi.loadResource(Rez.Drawables.AircraftApache) as Graphics.BitmapType,
            "asterisk" => WatchUi.loadResource(Rez.Drawables.AircraftAsterisk) as Graphics.BitmapType,
            "b1b_lancer" => WatchUi.loadResource(Rez.Drawables.AircraftB1bLancer) as Graphics.BitmapType,
            "b52" => WatchUi.loadResource(Rez.Drawables.AircraftB52) as Graphics.BitmapType,
            "b707" => WatchUi.loadResource(Rez.Drawables.AircraftB707) as Graphics.BitmapType,
            "b737" => WatchUi.loadResource(Rez.Drawables.AircraftB737) as Graphics.BitmapType,
            "b738" => WatchUi.loadResource(Rez.Drawables.AircraftB738) as Graphics.BitmapType,
            "b739" => WatchUi.loadResource(Rez.Drawables.AircraftB739) as Graphics.BitmapType,
            "bae_hawk" => WatchUi.loadResource(Rez.Drawables.AircraftBaeHawk) as Graphics.BitmapType,
            "balloon" => WatchUi.loadResource(Rez.Drawables.AircraftBalloon) as Graphics.BitmapType,
            "beluga" => WatchUi.loadResource(Rez.Drawables.AircraftBeluga) as Graphics.BitmapType,
            "blackhawk" => WatchUi.loadResource(Rez.Drawables.AircraftBlackhawk) as Graphics.BitmapType,
            "blimp" => WatchUi.loadResource(Rez.Drawables.AircraftBlimp) as Graphics.BitmapType,
            "c130" => WatchUi.loadResource(Rez.Drawables.AircraftC130) as Graphics.BitmapType,
            "c17" => WatchUi.loadResource(Rez.Drawables.AircraftC17) as Graphics.BitmapType,
            "c2" => WatchUi.loadResource(Rez.Drawables.AircraftC2) as Graphics.BitmapType,
            "c5" => WatchUi.loadResource(Rez.Drawables.AircraftC5) as Graphics.BitmapType,
            "cessna" => WatchUi.loadResource(Rez.Drawables.AircraftCessna) as Graphics.BitmapType,
            "chinook" => WatchUi.loadResource(Rez.Drawables.AircraftChinook) as Graphics.BitmapType,
            "cirrus_sr22" => WatchUi.loadResource(Rez.Drawables.AircraftCirrusSr22) as Graphics.BitmapType,
            "dauphin" => WatchUi.loadResource(Rez.Drawables.AircraftDauphin) as Graphics.BitmapType,
            "e390" => WatchUi.loadResource(Rez.Drawables.AircraftE390) as Graphics.BitmapType,
            "e3awacs" => WatchUi.loadResource(Rez.Drawables.AircraftE3awacs) as Graphics.BitmapType,
            "e737" => WatchUi.loadResource(Rez.Drawables.AircraftE737) as Graphics.BitmapType,
            "f18" => WatchUi.loadResource(Rez.Drawables.AircraftF18) as Graphics.BitmapType,
            "f35" => WatchUi.loadResource(Rez.Drawables.AircraftF35) as Graphics.BitmapType,
            "f5_tiger" => WatchUi.loadResource(Rez.Drawables.AircraftF5Tiger) as Graphics.BitmapType,
            "gazelle" => WatchUi.loadResource(Rez.Drawables.AircraftGazelle) as Graphics.BitmapType,
            "glider" => WatchUi.loadResource(Rez.Drawables.AircraftGlider) as Graphics.BitmapType,
            "ground_emergency" => WatchUi.loadResource(Rez.Drawables.AircraftGroundEmergency) as Graphics.BitmapType,
            "ground_fixed" => WatchUi.loadResource(Rez.Drawables.AircraftGroundFixed) as Graphics.BitmapType,
            "ground_service" => WatchUi.loadResource(Rez.Drawables.AircraftGroundService) as Graphics.BitmapType,
            "ground_square" => WatchUi.loadResource(Rez.Drawables.AircraftGroundSquare) as Graphics.BitmapType,
            "ground_tower" => WatchUi.loadResource(Rez.Drawables.AircraftGroundTower) as Graphics.BitmapType,
            "ground_unknown" => WatchUi.loadResource(Rez.Drawables.AircraftGroundUnknown) as Graphics.BitmapType,
            "gyrocopter" => WatchUi.loadResource(Rez.Drawables.AircraftGyrocopter) as Graphics.BitmapType,
            "heavy_2e" => WatchUi.loadResource(Rez.Drawables.AircraftHeavy2e) as Graphics.BitmapType,
            "heavy_4e" => WatchUi.loadResource(Rez.Drawables.AircraftHeavy4e) as Graphics.BitmapType,
            "helicopter" => WatchUi.loadResource(Rez.Drawables.AircraftHelicopter) as Graphics.BitmapType,
            "hi_perf" => WatchUi.loadResource(Rez.Drawables.AircraftHiPerf) as Graphics.BitmapType,
            "hunter" => WatchUi.loadResource(Rez.Drawables.AircraftHunter) as Graphics.BitmapType,
            "il_62" => WatchUi.loadResource(Rez.Drawables.AircraftIl62) as Graphics.BitmapType,
            "jet_nonswept" => WatchUi.loadResource(Rez.Drawables.AircraftJetNonswept) as Graphics.BitmapType,
            "jet_swept" => WatchUi.loadResource(Rez.Drawables.AircraftJetSwept) as Graphics.BitmapType,
            "l159" => WatchUi.loadResource(Rez.Drawables.AircraftL159) as Graphics.BitmapType,
            "lancaster" => WatchUi.loadResource(Rez.Drawables.AircraftLancaster) as Graphics.BitmapType,
            "m326" => WatchUi.loadResource(Rez.Drawables.AircraftM326) as Graphics.BitmapType,
            "md11" => WatchUi.loadResource(Rez.Drawables.AircraftMd11) as Graphics.BitmapType,
            "md_a4" => WatchUi.loadResource(Rez.Drawables.AircraftMdA4) as Graphics.BitmapType,
            "md_f15" => WatchUi.loadResource(Rez.Drawables.AircraftMdF15) as Graphics.BitmapType,
            "mil24" => WatchUi.loadResource(Rez.Drawables.AircraftMil24) as Graphics.BitmapType,
            "mirage" => WatchUi.loadResource(Rez.Drawables.AircraftMirage) as Graphics.BitmapType,
            "miragef1" => WatchUi.loadResource(Rez.Drawables.AircraftMiragef1) as Graphics.BitmapType,
            "p3_orion" => WatchUi.loadResource(Rez.Drawables.AircraftP3Orion) as Graphics.BitmapType,
            "p8" => WatchUi.loadResource(Rez.Drawables.AircraftP8) as Graphics.BitmapType,
            "pa24" => WatchUi.loadResource(Rez.Drawables.AircraftPa24) as Graphics.BitmapType,
            "para" => WatchUi.loadResource(Rez.Drawables.AircraftPara) as Graphics.BitmapType,
            "puma" => WatchUi.loadResource(Rez.Drawables.AircraftPuma) as Graphics.BitmapType,
            "rafale" => WatchUi.loadResource(Rez.Drawables.AircraftRafale) as Graphics.BitmapType,
            "rutan_veze" => WatchUi.loadResource(Rez.Drawables.AircraftRutanVeze) as Graphics.BitmapType,
            "s61" => WatchUi.loadResource(Rez.Drawables.AircraftS61) as Graphics.BitmapType,
            "sb39" => WatchUi.loadResource(Rez.Drawables.AircraftSb39) as Graphics.BitmapType,
            "single_turbo" => WatchUi.loadResource(Rez.Drawables.AircraftSingleTurbo) as Graphics.BitmapType,
            "strato" => WatchUi.loadResource(Rez.Drawables.AircraftStrato) as Graphics.BitmapType,
            "super_guppy" => WatchUi.loadResource(Rez.Drawables.AircraftSuperGuppy) as Graphics.BitmapType,
            "t38" => WatchUi.loadResource(Rez.Drawables.AircraftT38) as Graphics.BitmapType,
            "tiger" => WatchUi.loadResource(Rez.Drawables.AircraftTiger) as Graphics.BitmapType,
            "tornado" => WatchUi.loadResource(Rez.Drawables.AircraftTornado) as Graphics.BitmapType,
            "twin_large" => WatchUi.loadResource(Rez.Drawables.AircraftTwinLarge) as Graphics.BitmapType,
            "twin_small" => WatchUi.loadResource(Rez.Drawables.AircraftTwinSmall) as Graphics.BitmapType,
            "typhoon" => WatchUi.loadResource(Rez.Drawables.AircraftTyphoon) as Graphics.BitmapType,
            "u2" => WatchUi.loadResource(Rez.Drawables.AircraftU2) as Graphics.BitmapType,
            "uav" => WatchUi.loadResource(Rez.Drawables.AircraftUav) as Graphics.BitmapType,
            "unknown" => WatchUi.loadResource(Rez.Drawables.AircraftUnknown) as Graphics.BitmapType,
            "v22_fast" => WatchUi.loadResource(Rez.Drawables.AircraftV22Fast) as Graphics.BitmapType,
            "v22_slow" => WatchUi.loadResource(Rez.Drawables.AircraftV22Slow) as Graphics.BitmapType,
            "verhees" => WatchUi.loadResource(Rez.Drawables.AircraftVerhees) as Graphics.BitmapType,
            "wb57" => WatchUi.loadResource(Rez.Drawables.AircraftWb57) as Graphics.BitmapType,
        };
    }

    // A single recurring Timer, not two - a second always-on one alongside the poll timer hit Connect IQ's "Too Many Timers" limit.
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

    // Public so method(:_onTick) isn't optimized away as an unreferenced private symbol.
    public function _onTick() as Void {
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

        _ticksSincePoll += 1;
        var pollMs = POLL_MS_BY_ZOOM[Settings.zoomIndex];
        if (Settings.batterySaverMode) {
            pollMs *= BATTERY_SAVER_MULTIPLIER;
        }
        if (_ticksSincePoll * ANIM_TICK_MS >= pollMs) {
            _ticksSincePoll = 0;
            _fetchNow();
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
        _ticksSincePoll = 0;
        _fetchNow();
        WatchUi.requestUpdate();
    }

    public function zoomOut() as Void {
        Settings.zoomOut();
        _ticksSincePoll = 0;
        _fetchNow();
        WatchUi.requestUpdate();
    }

    public function recenter() as Void {
        if (_manualFocus != null) {
            _manualFocus = null;
            _fetchNow();
            WatchUi.requestUpdate();
            return;
        }
        if (_selectedHex != null) {
            deselectAircraft();
            return;
        }
        _fetchNow();
    }

    public function beginDrag(x as Number, y as Number) as Void {
        if (!_hasFix or _centerLat == null or _centerLon == null) {
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

    // True (and opens full detail) if (x,y) is inside the detail panel - it spans the full width, so only Y matters.
    public function tryOpenDetailPanel(x as Number, y as Number) as Boolean {
        var ac = _selectedAircraft();
        if (ac == null) {
            return false;
        }
        var panelH = _detailPanelHeight(ac as Aircraft);
        if (panelH == 0 || y < _lastScreenHeight - panelH - CHEVRON_TAP_MARGIN_PX) {
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
        // Same ring/panel geometry the radar itself uses (_lastRadiusPx/_lastScreenHeight are set every onUpdate, and this view can only open while the radar is showing) - so the boundary ring and top/bottom separators line up exactly with where they'd be on the radar underneath.
        var ringCx = _lastScreenHeight / 2;
        var view = new AircraftDetailView(
            header,
            _colorForAircraft(ac as Aircraft),
            built[0] as Array<Array<[String, String, Number]> >,
            built[1] as Number,
            ringCx,
            ringCx,
            _lastRadiusPx,
            _topPanelHeight(),
            _detailPanelHeight(ac as Aircraft)
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
        _openSky.fetchRoute(hex as String, method(:_onRouteResult));
    }

    // Public so method(:_onRouteResult) isn't optimized away as an unreferenced private symbol.
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
            // Reopened for a different aircraft mid-fetch - retry for what's actually showing, don't leave it stuck on "Loading...".
            _fetchSelectedRoute();
            return;
        }

        if (ok) {
            _routeFetchRetried = false;
            var resolved = dep != null || arr != null;
            (view as AircraftDetailView).setRouteText(
                _formatRoute(dep, arr),
                resolved ? COLOR_SUCCESS : COLOR_ROUTE_DIM
            );
            return;
        }

        if (!_routeFetchRetried) {
            _routeFetchRetried = true;
            _fetchSelectedRoute();
            return;
        }
        (view as AircraftDetailView).setRouteText("Unavailable", COLOR_ROUTE_DIM);
    }

    private function _formatRoute(dep as String?, arr as String?) as String {
        if (dep == null && arr == null) {
            return "Unknown";
        }
        return (dep != null ? dep : "?") + " -> " + (arr != null ? arr : "?");
    }

    // Called from AircraftDetailDelegate once the pushed view is popped, so a late route result has nothing left to update.
    public function onDetailClosed() as Void {
        _detailView = null;
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

    // Public so method(:_onTrackResult) isn't optimized away as an unreferenced private symbol.
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
            return;
        }
        if (!_hasFix or _centerLat == null or _centerLon == null) {
            return;
        }
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

    // Public so method(:_onFetchResult) isn't optimized away as an unreferenced private symbol.
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
            var byHex = ({}) as Dictionary<String, Aircraft>;
            for (var i = 0; i < aircraft.size(); i++) {
                byHex[aircraft[i].hex] = aircraft[i];
            }
            _aircraft = aircraft;
            _aircraftByHex = byHex;

            var selected = _selectedHex;
            if (selected != null) {
                var selectedAc = byHex[selected];
                if (selectedAc == null) {
                    _selectedMissCount += 1;
                    if (_selectedMissCount >= MAX_SELECTED_MISSES) {
                        // _focusPoint() would fall through to the user's own position here - the aircraft is already missing from _aircraftByHex, so freeze on the last confirmed fix instead.
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
        var radiusPx = (w < h ? w : h) / 2 - EDGE_MARGIN;
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
        _drawAircraft(dc, focusLat, focusLon, cx, cy, radiusPx, radiusKm);

        if (selected != null) {
            _drawDetailPanel(dc, cx, cy, h, radiusPx, selected as Aircraft);
        }

        _drawTopPanel(dc, cx, cy, radiusPx);

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

        if (Settings.showButtonHints) {
            _drawButtonHints(dc, cx, cy, radiusPx);
        }
    }

    private function _focusPoint() as [Float, Float] {
        var manual = _manualFocus;
        if (manual != null) {
            return manual as [Float, Float];
        }
        var selected = _selectedAircraft();
        if (selected != null) {
            return [(selected as Aircraft).lat, (selected as Aircraft).lon];
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
                    dc.setStroke(_withAlpha(COLOR_RING, COLOR_RING_ALPHA));
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
        dc.setStroke(_withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawCircle(cx, cy, radiusPx);
        // White, not the usual dim grid-label grey - this is the actual current zoom level, not a secondary reference ring.
        _drawRingLabel(
            dc,
            cx,
            cy,
            radiusPx,
            radiusKm,
            topPanelH,
            COLORS[0]
        );

        if (Settings.showRangeRings) {
            for (var deg = 0; deg < 360; deg += 30) {
                var cardinal = deg % 90 == 0;
                dc.setStroke(
                    _withAlpha(
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

    // Zoom in (KEY_UP). White, not COLOR_TEXT - matches the chevron's brightness instead of reading fainter/thinner next to it.
    private function _drawPlusHint(dc as Dc, x as Number, y as Number) as Void {
        _setSolidColor(dc, COLORS[0]);
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
        _setSolidColor(dc, COLORS[0]);
        var s = 6;
        dc.drawLine(x - s, y, x + s, y);
    }

    // Menu (KEY_ENTER/KEY_MENU).
    private function _drawMenuHint(dc as Dc, x as Number, y as Number) as Void {
        _setSolidColor(dc, COLORS[0]);
        var s = 4;
        dc.drawLine(x - s, y - 3, x + s, y - 3);
        dc.drawLine(x - s, y, x + s, y);
        dc.drawLine(x - s, y + 3, x + s, y + 3);
    }

    // Recenter (KEY_ESC) - a crosshair with a gap at the center, not a solid "+", so it doesn't read as a duplicate of the zoom-in hint.
    private function _drawRecenterHint(
        dc as Dc,
        x as Number,
        y as Number
    ) as Void {
        _setSolidColor(dc, COLORS[0]);
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
        if (_fetchInFlight) {
            return [_fetchingText, COLOR_GRID_LABEL];
        }
        return [_fetchedText, COLOR_SUCCESS];
    }

    private function _topPanelHeight() as Number {
        return _topPanelLines().size() * TOP_PANEL_LINE_HEIGHT + 8;
    }

    private function _drawTopPanel(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number
    ) as Void {
        var lines = _topPanelLines();
        var panelH = lines.size() * TOP_PANEL_LINE_HEIGHT + 8;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, dc.getWidth(), panelH);

        for (var i = 0; i < lines.size(); i++) {
            var line = lines[i];
            dc.setColor(line[1] as Number, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                4 + i * TOP_PANEL_LINE_HEIGHT,
                _fontTiny,
                line[0] as String,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        if (_fetchInFlight && !_fetchTimedOutDisplay) {
            _drawFetchSpinner(
                dc,
                dc.getWidth() - 12,
                TOP_PANEL_LINE_HEIGHT / 2 + 4
            );
        }

        _drawPanelBorder(dc, panelH, cx, cy, radiusPx);
    }

    private const FETCH_SPINNER_R = 5;
    private const FETCH_SPINNER_DOT_R = 2;
    private const FETCH_SPINNER_PERIOD_MS = 1200;

    // A dot orbiting a small ring, not a static dot - no rotational symmetry to alias against, so it reads as motion even at ANIM_TICK_MS's redraw rate.
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
        _setSolidColor(dc, COLOR_TEXT);
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
        var halfW = _chordHalfExtent(radiusPx, dy);
        // COLOR_BOUNDARY_ALPHA, not COLOR_RING_ALPHA - this line is meant to read as a continuation of the boundary ring itself, so it needs the same opacity, not the dimmer one used for the secondary range rings.
        dc.setStroke(_withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
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
            var halfW = _chordHalfExtent(radiusPx, dy);
            dc.setStroke(_withAlpha(COLOR_GRID, COLOR_GRID_ALPHA));
            dc.drawLine(cx - halfW, pt[1], cx + halfW, pt[1]);
            if (pt[1] > topPanelH && pt[1] < bottomLimitY) {
                _drawGridLabel(
                    dc,
                    cx - halfW + GRID_LABEL_INSET,
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
            var halfH = _chordHalfExtent(radiusPx, dx);
            var lineTop = cy - halfH;
            var lineBottom = cy + halfH;
            dc.setStroke(_withAlpha(COLOR_GRID, COLOR_GRID_ALPHA));
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

        _setSolidColor(dc, COLOR_USER);
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

        _setSolidColor(dc, COLOR_USER);
        dc.fillPolygon(pts);
    }

    // setStroke needs an explicit alpha byte and isn't reset by setColor - reasserts both for a fully opaque draw.
    private function _setSolidColor(dc as Dc, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        // 0xfe, not 0xff - packing white (0xffffff) at alpha 0xff produces exactly 0xFFFFFFFF, which as a signed 32-bit Number equals -1, the same bit pattern as Graphics.COLOR_TRANSPARENT - setStroke silently treats it as "no stroke" instead of "opaque white" (this is what made the up-chevron invisible). 0xfe is visually indistinguishable from fully opaque and can never collide with -1 for any RGB color.
        dc.setStroke(_withAlpha(color, 0xfe));
    }

    private function _withAlpha(color as Number, alpha as Number) as Number {
        return (alpha << 24) | (color & 0xffffff);
    }

    // Half-length of the chord of the radar circle at a given perpendicular offset from center.
    private function _chordHalfExtent(
        radiusPx as Number,
        offsetPx as Number
    ) as Number {
        return Math.sqrt(
            (radiusPx * radiusPx - offsetPx * offsetPx).toFloat()
        ).toNumber();
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

    // Skips rects owned by hex itself - a label may freely sit over its own icon/chevron/reticle, only another aircraft's counts as a clip.
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
                if (!Settings.showGroundVehicles && isGroundVehicle) {
                    continue;
                }
                if (Settings.hideObstacles && ac.isObstacle()) {
                    continue;
                }
                if (
                    Settings.hideGroundedPlanes &&
                    ac.onGround &&
                    !isGroundVehicle
                ) {
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

            // Drawn before the icon itself, so the real icon paints over the outline's interior.
            if (ac.isEmergency()) {
                _drawIconHalo(dc, pos[0], pos[1], ac, COLOR_EMERGENCY);
            }
            _drawAircraftIcon(dc, pos[0], pos[1], ac);
            if (Settings.showVertRateChevron) {
                _drawVertRateChevron(dc, pos[0], pos[1], ac);
            }

            // Reserved for every aircraft, ahead of the label pass - a label must never cover any icon or clip any climb/descend chevron, not just the selected one's.
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

            if (isSelected) {
                _drawSelectionReticle(dc, pos[0], pos[1], ac);
                _reserveRect(ac.hex, _selectionReticleRect(pos[0], pos[1], ac));
            }
        }

        // A separate pass, after every icon - otherwise a later aircraft's label could paint over an earlier aircraft's icon.
        if (Settings.labelsEnabled) {
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
            // Drawn/registered before the rest, so its rect is already reserved - an overlapping non-selected label loses the spot instead of both rendering on top of each other.
            if (selectedIndex >= 0) {
                var selEntry = _lastDrawnPositions[selectedIndex];
                var selAc = _aircraftByHex[selEntry[0] as String];
                if (selAc != null) {
                    _drawAircraftLabel(
                        dc,
                        selEntry[1] as Number,
                        selEntry[2] as Number,
                        selAc as Aircraft,
                        true
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
                    false
                );
            }

            // Re-drawn on top of every label, so the selected craft's own icon/reticle/chevron can never end up visually behind another aircraft's label.
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

    // Bigger-class aircraft's label wins any overlap over a smaller one's - plain insertion sort, on-screen counts are small enough that this is cheap.
    private function _labelDrawOrder(selectedIndex as Number) as Array<Number> {
        var order = [] as Array<Number>;
        for (var i = 0; i < _lastDrawnPositions.size(); i++) {
            if (i != selectedIndex) {
                order.add(i);
            }
        }
        for (var i = 1; i < order.size(); i++) {
            var key = order[i];
            var keyScale = _sizeScaleForIndex(key);
            var j = i - 1;
            while (j >= 0 && _sizeScaleForIndex(order[j]) < keyScale) {
                order[j + 1] = order[j];
                j -= 1;
            }
            order[j + 1] = key;
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
        if (ac.isEmergency()) {
            _drawIconHalo(dc, x, y, ac, COLOR_EMERGENCY);
        }
        _drawAircraftIcon(dc, x, y, ac);
        if (Settings.showVertRateChevron) {
            _drawVertRateChevron(dc, x, y, ac);
        }
        _drawSelectionReticle(dc, x, y, ac);
    }

    // Flat aircraft-color line (the altitude gradient was tried and dropped - looked messy/inconsistent, see [[selection_declutter_history]]). Ground/taxi segments use the same color at a lower opacity instead of a separate gray, so the dashed part still reads as "the same track", just dimmer.
    private const TRAIL_DASH_PX = 5.0;
    private const TRAIL_GAP_PX = 4.0;
    private const TRAIL_MAX_DASHES_PER_SEGMENT = 24;
    private const COLOR_TRAIL_GROUND_ALPHA = 0x50;

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
                        _withAlpha(trailColor, COLOR_TRAIL_GROUND_ALPHA)
                    );
                    _drawDashedLine(dc, p0[0], p0[1], screen[0], screen[1]);
                } else {
                    dc.setStroke(_withAlpha(trailColor, COLOR_TRAIL_ALPHA));
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
    // 0.34 * (2.0/3.0): source PNGs render at 3px/unit now (was 2px/unit) for more retained detail, compensated here so on-screen size is unchanged.
    private const ICON_BASE_SCALE = 0.226667;
    private const ICON_RECT_MARGIN = 2;

    // Half-diagonal (content px, scale 1.0) of each shape's actual rendered art bbox - content size varies far more across this 89-shape tar1090 roster than the old 28, so this is genuinely per-shape, not a shared constant.
    private const ICON_HALF_DIAGONAL as Dictionary<String, Float> = {
        "a10" => 49.5,
        "a225" => 76.0,
        "a319" => 67.5,
        "a320" => 64.8,
        "a321" => 60.9,
        "a332" => 65.1,
        "a359" => 65.8,
        "a380" => 85.6,
        "a400" => 69.4,
        "airliner" => 64.8,
        "alpha_jet" => 55.6,
        "apache" => 57.3,
        "asterisk" => 22.6,
        "b1b_lancer" => 65.8,
        "b52" => 77.8,
        "b707" => 67.2,
        "b737" => 67.5,
        "b738" => 62.8,
        "b739" => 61.2,
        "bae_hawk" => 64.6,
        "balloon" => 30.9,
        "beluga" => 55.5,
        "blackhawk" => 51.6,
        "blimp" => 50.6,
        "c130" => 63.1,
        "c17" => 67.5,
        "c2" => 58.2,
        "c5" => 64.8,
        "cessna" => 48.0,
        "chinook" => 56.9,
        "cirrus_sr22" => 46.5,
        "dauphin" => 51.3,
        "e390" => 66.8,
        "e3awacs" => 75.3,
        "e737" => 67.9,
        "f18" => 47.1,
        "f35" => 58.2,
        "f5_tiger" => 49.1,
        "gazelle" => 52.5,
        "glider" => 54.6,
        "ground_emergency" => 29.5,
        "ground_fixed" => 25.5,
        "ground_service" => 29.5,
        "ground_square" => 23.3,
        "ground_tower" => 42.0,
        "ground_unknown" => 29.5,
        "gyrocopter" => 48.7,
        "heavy_2e" => 67.7,
        "heavy_4e" => 69.4,
        "helicopter" => 53.1,
        "hi_perf" => 58.5,
        "hunter" => 48.3,
        "il_62" => 57.3,
        "jet_nonswept" => 46.7,
        "jet_swept" => 46.8,
        "l159" => 52.5,
        "lancaster" => 50.5,
        "m326" => 52.3,
        "md11" => 73.9,
        "md_a4" => 46.6,
        "md_f15" => 50.5,
        "mil24" => 62.2,
        "mirage" => 49.9,
        "miragef1" => 60.2,
        "p3_orion" => 56.6,
        "p8" => 66.5,
        "pa24" => 58.3,
        "para" => 38.8,
        "puma" => 50.2,
        "rafale" => 46.8,
        "rutan_veze" => 50.7,
        "s61" => 55.6,
        "sb39" => 52.0,
        "single_turbo" => 50.2,
        "strato" => 69.2,
        "super_guppy" => 57.7,
        "t38" => 47.9,
        "tiger" => 53.7,
        "tornado" => 49.3,
        "twin_large" => 51.6,
        "twin_small" => 49.0,
        "typhoon" => 45.1,
        "u2" => 56.6,
        "uav" => 48.4,
        "unknown" => 46.0,
        "v22_fast" => 50.5,
        "v22_slow" => 50.8,
        "verhees" => 53.1,
        "wb57" => 48.6,
    };

    // [canvasHalfW, canvasHalfH] per shape - the AffineTransform rotation pivot. Canvases are sized per-shape (content + a few px margin), not one shared square, so this can't be a single constant either.
    private const ICON_PIVOT as Dictionary<String, [Float, Float]> = {
        "a10" => [42.0, 40.0] as [Float, Float],
        "a225" => [60.0, 60.0] as [Float, Float],
        "a319" => [54.0, 54.0] as [Float, Float],
        "a320" => [50.0, 54.0] as [Float, Float],
        "a321" => [44.0, 54.0] as [Float, Float],
        "a332" => [53.0, 52.0] as [Float, Float],
        "a359" => [52.0, 53.0] as [Float, Float],
        "a380" => [69.0, 64.0] as [Float, Float],
        "a400" => [53.0, 57.0] as [Float, Float],
        "airliner" => [50.0, 54.0] as [Float, Float],
        "alpha_jet" => [43.0, 48.0] as [Float, Float],
        "apache" => [40.0, 53.0] as [Float, Float],
        "asterisk" => [22.0, 23.0] as [Float, Float],
        "b1b_lancer" => [51.0, 54.0] as [Float, Float],
        "b52" => [66.0, 56.0] as [Float, Float],
        "b707" => [54.0, 53.0] as [Float, Float],
        "b737" => [54.0, 54.0] as [Float, Float],
        "b738" => [47.0, 54.0] as [Float, Float],
        "b739" => [44.0, 54.0] as [Float, Float],
        "bae_hawk" => [48.0, 56.0] as [Float, Float],
        "balloon" => [24.0, 32.0] as [Float, Float],
        "beluga" => [41.0, 50.0] as [Float, Float],
        "blackhawk" => [36.0, 48.0] as [Float, Float],
        "blimp" => [22.0, 54.0] as [Float, Float],
        "c130" => [59.0, 41.0] as [Float, Float],
        "c17" => [54.0, 54.0] as [Float, Float],
        "c2" => [54.0, 39.0] as [Float, Float],
        "c5" => [50.0, 54.0] as [Float, Float],
        "cessna" => [45.0, 34.0] as [Float, Float],
        "chinook" => [37.0, 54.0] as [Float, Float],
        "cirrus_sr22" => [44.0, 34.0] as [Float, Float],
        "dauphin" => [36.0, 48.0] as [Float, Float],
        "e390" => [54.0, 53.0] as [Float, Float],
        "e3awacs" => [59.0, 60.0] as [Float, Float],
        "e737" => [54.0, 54.0] as [Float, Float],
        "f18" => [35.0, 44.0] as [Float, Float],
        "f35" => [39.0, 54.0] as [Float, Float],
        "f5_tiger" => [32.0, 48.0] as [Float, Float],
        "gazelle" => [38.0, 48.0] as [Float, Float],
        "glider" => [56.0, 29.0] as [Float, Float],
        "ground_emergency" => [18.0, 33.0] as [Float, Float],
        "ground_fixed" => [24.0, 24.0] as [Float, Float],
        "ground_service" => [18.0, 33.0] as [Float, Float],
        "ground_square" => [23.0, 23.0] as [Float, Float],
        "ground_tower" => [39.0, 32.0] as [Float, Float],
        "ground_unknown" => [18.0, 33.0] as [Float, Float],
        "gyrocopter" => [47.0, 33.0] as [Float, Float],
        "heavy_2e" => [51.0, 57.0] as [Float, Float],
        "heavy_4e" => [53.0, 57.0] as [Float, Float],
        "helicopter" => [37.0, 50.0] as [Float, Float],
        "hi_perf" => [40.0, 54.0] as [Float, Float],
        "hunter" => [35.0, 45.0] as [Float, Float],
        "il_62" => [42.0, 51.0] as [Float, Float],
        "jet_nonswept" => [39.0, 39.0] as [Float, Float],
        "jet_swept" => [34.0, 44.0] as [Float, Float],
        "l159" => [38.0, 48.0] as [Float, Float],
        "lancaster" => [48.0, 34.0] as [Float, Float],
        "m326" => [44.0, 43.0] as [Float, Float],
        "md11" => [53.0, 63.0] as [Float, Float],
        "md_a4" => [32.0, 45.0] as [Float, Float],
        "md_f15" => [34.0, 48.0] as [Float, Float],
        "mil24" => [46.0, 54.0] as [Float, Float],
        "mirage" => [33.0, 48.0] as [Float, Float],
        "miragef1" => [36.0, 59.0] as [Float, Float],
        "p3_orion" => [44.0, 48.0] as [Float, Float],
        "p8" => [52.0, 54.0] as [Float, Float],
        "pa24" => [51.0, 43.0] as [Float, Float],
        "para" => [44.0, 16.0] as [Float, Float],
        "puma" => [34.0, 48.0] as [Float, Float],
        "rafale" => [34.0, 44.0] as [Float, Float],
        "rutan_veze" => [47.0, 37.0] as [Float, Float],
        "s61" => [43.0, 48.0] as [Float, Float],
        "sb39" => [35.0, 50.0] as [Float, Float],
        "single_turbo" => [41.0, 42.0] as [Float, Float],
        "strato" => [66.0, 41.0] as [Float, Float],
        "super_guppy" => [48.0, 46.0] as [Float, Float],
        "t38" => [29.0, 48.0] as [Float, Float],
        "tiger" => [40.0, 48.0] as [Float, Float],
        "tornado" => [38.0, 44.0] as [Float, Float],
        "twin_large" => [44.0, 42.0] as [Float, Float],
        "twin_small" => [44.0, 38.0] as [Float, Float],
        "typhoon" => [31.0, 44.0] as [Float, Float],
        "u2" => [54.0, 36.0] as [Float, Float],
        "uav" => [48.0, 30.0] as [Float, Float],
        "unknown" => [39.0, 38.0] as [Float, Float],
        "v22_fast" => [48.0, 34.0] as [Float, Float],
        "v22_slow" => [48.0, 35.0] as [Float, Float],
        "verhees" => [48.0, 39.0] as [Float, Float],
        "wb57" => [48.0, 31.0] as [Float, Float],
    };

    private function _iconHalfExtent(ac as Aircraft) as Number {
        var diag = ICON_HALF_DIAGONAL[_shapeKeyForAircraft(ac)];
        var srcHalf = diag != null ? diag as Float : 30.0;
        var scale = ICON_BASE_SCALE * _sizeScaleForAircraft(ac);
        return (srcHalf * scale).toNumber();
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

    // Helicopters draw a real rotated body silhouette matched by type (e.g. H60->blackhawk), same as fixed-wing - no separate rotor overlay, the body art already depicts the rotor.
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
        _drawIconVariant(dc, x, y, ac, color, 0, 0);
    }

    private const OUTLINE_PX = 2.0;
    // 8-direction offset-blit of the same bitmap, not a second dilated asset - see icon_rendering_history memory for why uniform scaling was rejected.
    private const OUTLINE_OFFSETS as Array<[Float, Float]> = [
        [1.0, 0.0],
        [-1.0, 0.0],
        [0.0, 1.0],
        [0.0, -1.0],
        [0.7071, 0.7071],
        [0.7071, -0.7071],
        [-0.7071, 0.7071],
        [-0.7071, -0.7071],
    ] as Array<[Float, Float]>;

    private function _drawIconHalo(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        color as Number
    ) as Void {
        for (var i = 0; i < OUTLINE_OFFSETS.size(); i++) {
            var off = OUTLINE_OFFSETS[i];
            _drawIconVariant(
                dc,
                x,
                y,
                ac,
                color,
                (off[0] * OUTLINE_PX).toNumber(),
                (off[1] * OUTLINE_PX).toNumber()
            );
        }
    }

    private const SELECTION_ARROW_LEN = 7.0;
    private const SELECTION_ARROW_WIDTH = 5.0;
    private const SELECTION_RECT_MARGIN = 2;
    // Shared clearance beyond the icon's own rendered extent - both the reticle and the vert-rate chevron sit this far past the actual icon edge, not a separately-tuned radius.
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
        _setSolidColor(dc, COLOR_SELECTED);
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

    // Rotated bitmap + AffineTransform, tinted via :tintColor. offsetX/Y let _drawIconHalo reuse this call shifted a few px - no default-parameter syntax in Monkey C, so plain draws just pass 0, 0.
    private function _drawIconVariant(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        color as Number,
        offsetX as Number,
        offsetY as Number
    ) as Void {
        var track = ac.track;
        var theta = track != null ? Math.toRadians(track) : 0.0;

        var scale = ICON_BASE_SCALE * _sizeScaleForAircraft(ac);
        var shape = _shapeKeyForAircraft(ac);
        var pivot = ICON_PIVOT[shape];
        var halfW = pivot != null ? (pivot as [Float, Float])[0] : 30.0;
        var halfH = pivot != null ? (pivot as [Float, Float])[1] : 30.0;

        var tf = new Graphics.AffineTransform();
        tf.translate((x + offsetX).toFloat(), (y + offsetY).toFloat());
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

    // Shared by _drawVertRateChevron and _chevronRect, so the declutter rect always matches where the chevron actually draws.
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
        // Placed by angle+radius past the icon's own extent, not a flat x/y offset or a separately-tuned radius - the old fixed CHEVRON_RADIUS sat too close on small (light-category) icons.
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
        _setSolidColor(dc, _colorForAircraft(ac));
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

    // Not exhaustive - just a safety net so a typeCode-recognizable jet with missing category isn't misclassified as light. MTOW-verified real DO-260B tier (75,000-300,000lbs), not guessed.
    private const LARGE_TYPE_CODES as Array<String> = [
        "A319",
        "A320",
        "A321",
        "A332",
        "A333",
        "A338",
        "A339",
        "B737",
        "B738",
        "B739",
        "B37M",
        "B38M",
        "B39M",
        "B752",
        "B753",
        "C130",
    ];

    // MTOW-verified >300,000lbs (real DO-260B A5 threshold) - includes large military transports, which commonly omit category entirely, unlike this list's civilian entries.
    private const SUPER_HEAVY_TYPE_CODES as Array<String> = [
        "B762",
        "B763",
        "B764",
        "B772",
        "B773",
        "B77L",
        "B77W",
        "B788",
        "B789",
        "B78X",
        "B742",
        "B743",
        "B744",
        "B748",
        "A342",
        "A343",
        "A345",
        "A346",
        "A388",
        "MD11",
        "C5M",
        "C17",
        "K35R",
    ];

    // Exact ICAO type designator -> tar1090 icon shape key, from icao_type_designator_to_icon.csv - checked before category.
    private const TYPE_TO_ICON as Dictionary<String, String> = {
        "SHIP" => "blimp",
        "BALL" => "balloon",
        "A318" => "a319",
        "A319" => "a319",
        "A19N" => "a319",
        "A320" => "a320",
        "A20N" => "a320",
        "A321" => "a321",
        "A21N" => "a321",
        "A306" => "heavy_2e",
        "A330" => "a332",
        "A332" => "a332",
        "A333" => "a332",
        "A338" => "a332",
        "A339" => "a332",
        "DC10" => "md11",
        "MD11" => "md11",
        "A359" => "a359",
        "A35K" => "a359",
        "A388" => "a380",
        "B731" => "b737",
        "B732" => "b737",
        "B735" => "b737",
        "B733" => "b737",
        "B734" => "b737",
        "B736" => "b737",
        "B737" => "b737",
        "B738" => "b738",
        "B739" => "b739",
        "B37M" => "b737",
        "B38M" => "b738",
        "B39M" => "b739",
        "B3XM" => "b739",
        "P8" => "p8",
        "E737" => "e737",
        "J328" => "airliner",
        "E170" => "airliner",
        "E75S/L" => "airliner",
        "E75L" => "airliner",
        "E75S" => "airliner",
        "A148" => "airliner",
        "RJ70" => "b707",
        "RJ85" => "b707",
        "RJ1H" => "b707",
        "B461" => "b707",
        "B462" => "b707",
        "B463" => "b707",
        "E190" => "airliner",
        "E195" => "airliner",
        "E290" => "airliner",
        "E295" => "airliner",
        "BCS1" => "airliner",
        "BCS3" => "airliner",
        "B741" => "heavy_4e",
        "B742" => "heavy_4e",
        "B743" => "heavy_4e",
        "B744" => "heavy_4e",
        "B74D" => "heavy_4e",
        "B74S" => "heavy_4e",
        "B74R" => "heavy_4e",
        "BLCF" => "heavy_4e",
        "BSCA" => "heavy_4e",
        "B748" => "heavy_4e",
        "B752" => "heavy_2e",
        "B753" => "heavy_2e",
        "B772" => "heavy_2e",
        "B773" => "heavy_2e",
        "B77L" => "heavy_2e",
        "B77W" => "heavy_2e",
        "B701" => "b707",
        "B703" => "b707",
        "K35R" => "b707",
        "K35E" => "b707",
        "FA20" => "jet_swept",
        "C680" => "jet_swept",
        "C68A" => "jet_swept",
        "YK40" => "jet_swept",
        "C750" => "jet_swept",
        "F2TH" => "jet_swept",
        "FA50" => "jet_swept",
        "CL30" => "jet_swept",
        "CL35" => "jet_swept",
        "F900" => "jet_swept",
        "CL60" => "jet_swept",
        "G200" => "jet_swept",
        "G280" => "jet_swept",
        "HA4T" => "jet_swept",
        "FA7X" => "jet_swept",
        "FA8X" => "jet_swept",
        "FA6X" => "jet_swept",
        "GLF2" => "jet_swept",
        "GLF3" => "jet_swept",
        "GLF4" => "jet_swept",
        "GA5C" => "jet_swept",
        "GL5T" => "jet_swept",
        "GLF5" => "jet_swept",
        "GA6C" => "jet_swept",
        "GLEX" => "jet_swept",
        "GL6T" => "jet_swept",
        "GLF6" => "jet_swept",
        "GA7C" => "jet_swept",
        "GA8C" => "jet_swept",
        "GL7T" => "jet_swept",
        "E135" => "jet_swept",
        "E35L" => "jet_swept",
        "E145" => "jet_swept",
        "E45X" => "jet_swept",
        "E390" => "e390",
        "CRJ1" => "jet_swept",
        "CRJ2" => "jet_swept",
        "F28" => "jet_swept",
        "CRJ7" => "jet_swept",
        "CRJ9" => "jet_swept",
        "F70" => "jet_swept",
        "CRJX" => "jet_swept",
        "F100" => "jet_swept",
        "DC91" => "jet_swept",
        "DC92" => "jet_swept",
        "DC93" => "jet_swept",
        "DC94" => "jet_swept",
        "DC95" => "jet_swept",
        "MD80" => "jet_swept",
        "MD81" => "jet_swept",
        "MD82" => "jet_swept",
        "MD83" => "jet_swept",
        "MD87" => "jet_swept",
        "MD88" => "jet_swept",
        "MD90" => "jet_swept",
        "B712" => "jet_swept",
        "B721" => "jet_swept",
        "B722" => "jet_swept",
        "T154" => "jet_swept",
        "BE40" => "jet_nonswept",
        "FA10" => "jet_nonswept",
        "C501" => "jet_nonswept",
        "C510" => "jet_nonswept",
        "C25A" => "jet_nonswept",
        "C25B" => "jet_nonswept",
        "C25C" => "jet_nonswept",
        "C525" => "jet_nonswept",
        "C550" => "jet_nonswept",
        "C560" => "jet_nonswept",
        "C56X" => "jet_nonswept",
        "LJ23" => "jet_nonswept",
        "LJ24" => "jet_nonswept",
        "LJ25" => "jet_nonswept",
        "LJ28" => "jet_nonswept",
        "LJ31" => "jet_nonswept",
        "LJ35" => "jet_nonswept",
        "LR35" => "jet_nonswept",
        "LJ40" => "jet_nonswept",
        "LJ45" => "jet_nonswept",
        "LR45" => "jet_nonswept",
        "LJ55" => "jet_nonswept",
        "LJ60" => "jet_nonswept",
        "LJ70" => "jet_nonswept",
        "LJ75" => "jet_nonswept",
        "LJ85" => "jet_nonswept",
        "C650" => "jet_nonswept",
        "ASTR" => "jet_nonswept",
        "G150" => "jet_nonswept",
        "H25A" => "jet_nonswept",
        "H25B" => "jet_nonswept",
        "H25C" => "jet_nonswept",
        "PRM1" => "jet_nonswept",
        "E55P" => "jet_nonswept",
        "E50P" => "jet_nonswept",
        "EA50" => "jet_nonswept",
        "HDJT" => "jet_nonswept",
        "SF50" => "jet_nonswept",
        "C97" => "super_guppy",
        "SGUP" => "super_guppy",
        "A3ST" => "beluga",
        "A337" => "beluga",
        "WB57" => "wb57",
        "A37" => "hi_perf",
        "A700" => "hi_perf",
        "LEOP" => "hi_perf",
        "ME62" => "hi_perf",
        "T2" => "hi_perf",
        "T37" => "hi_perf",
        "T38" => "t38",
        "F104" => "t38",
        "A10" => "a10",
        "A3" => "hi_perf",
        "A6" => "hi_perf",
        "AJET" => "alpha_jet",
        "AT3" => "hi_perf",
        "CKUO" => "hi_perf",
        "EUFI" => "typhoon",
        "SB39" => "sb39",
        "MIR2" => "mirage",
        "KFIR" => "mirage",
        "F1" => "hi_perf",
        "F111" => "hi_perf",
        "F117" => "hi_perf",
        "F14" => "hi_perf",
        "F15" => "md_f15",
        "F16" => "hi_perf",
        "F18" => "f18",
        "F18H" => "f18",
        "F18S" => "f18",
        "F22" => "f35",
        "F22A" => "f35",
        "F35" => "f35",
        "VF35" => "f35",
        "L159" => "l159",
        "L39" => "l159",
        "F4" => "hi_perf",
        "F5" => "f5_tiger",
        "HUNT" => "hunter",
        "LANC" => "lancaster",
        "B17" => "lancaster",
        "B29" => "lancaster",
        "J8A" => "hi_perf",
        "J8B" => "hi_perf",
        "JH7" => "hi_perf",
        "LTNG" => "hi_perf",
        "M346" => "hi_perf",
        "METR" => "hi_perf",
        "MG19" => "hi_perf",
        "MG25" => "hi_perf",
        "MG29" => "hi_perf",
        "MG31" => "hi_perf",
        "MG44" => "hi_perf",
        "MIR4" => "hi_perf",
        "MT2" => "hi_perf",
        "Q5" => "hi_perf",
        "RFAL" => "rafale",
        "S3" => "hi_perf",
        "S37" => "hi_perf",
        "SR71" => "hi_perf",
        "SU15" => "hi_perf",
        "SU24" => "hi_perf",
        "SU25" => "hi_perf",
        "SU27" => "hi_perf",
        "T22M" => "hi_perf",
        "T4" => "hi_perf",
        "TOR" => "tornado",
        "A4" => "md_a4",
        "TU22" => "hi_perf",
        "VAUT" => "hi_perf",
        "Y130" => "hi_perf",
        "YK28" => "hi_perf",
        "BE20" => "twin_large",
        "IL62" => "il_62",
        "MRF1" => "miragef1",
        "M326" => "m326",
        "M339" => "m326",
        "FOUG" => "m326",
        "T33" => "m326",
        "A225" => "a225",
        "A124" => "b707",
        "SLCH" => "strato",
        "WHK2" => "strato",
        "C130" => "c130",
        "C30J" => "c130",
        "P3" => "p3_orion",
        "PARA" => "para",
        "DRON" => "uav",
        "Q1" => "uav",
        "Q4" => "uav",
        "Q9" => "uav",
        "Q25" => "uav",
        "HRON" => "uav",
        "A400" => "a400",
        "V22F" => "v22_fast",
        "V22" => "v22_slow",
        "B609F" => "v22_fast",
        "B609" => "v22_slow",
        "H64" => "apache",
        "H60" => "blackhawk",
        "S92" => "blackhawk",
        "NH90" => "blackhawk",
        "AS32" => "puma",
        "AS3B" => "puma",
        "PUMA" => "puma",
        "TIGR" => "tiger",
        "MI24" => "mil24",
        "AS65" => "dauphin",
        "S76" => "dauphin",
        "GAZL" => "gazelle",
        "AS50" => "gazelle",
        "AS55" => "gazelle",
        "ALO2" => "gazelle",
        "ALO3" => "gazelle",
        "R22" => "helicopter",
        "R44" => "helicopter",
        "R66" => "helicopter",
        "EC55" => "s61",
        "A169" => "s61",
        "H160" => "s61",
        "A139" => "s61",
        "EC75" => "s61",
        "A189" => "s61",
        "A149" => "s61",
        "S61" => "s61",
        "S61R" => "s61",
        "EC25" => "s61",
        "EH10" => "s61",
        "H53" => "s61",
        "H53S" => "s61",
        "U2" => "u2",
        "C2" => "c2",
        "E2" => "c2",
        "H47" => "chinook",
        "H46" => "chinook",
        "HAWK" => "bae_hawk",
        "GYRO" => "gyrocopter",
        "DLTA" => "verhees",
        "B1" => "b1b_lancer",
        "B52" => "b52",
        "C17" => "c17",
        "C5M" => "c5",
        "E3TF" => "e3awacs",
        "E3CF" => "e3awacs",
        "GLID" => "glider",
        "S6" => "glider",
        "S10S" => "glider",
        "S12" => "glider",
        "S12S" => "glider",
        "ARCE" => "glider",
        "ARCP" => "glider",
        "DISC" => "glider",
        "DUOD" => "glider",
        "JANU" => "glider",
        "NIMB" => "glider",
        "QINT" => "glider",
        "VENT" => "glider",
        "VNTE" => "glider",
        "A20J" => "glider",
        "A32E" => "glider",
        "A32P" => "glider",
        "A33E" => "glider",
        "A33P" => "glider",
        "A34E" => "glider",
        "AS14" => "glider",
        "AS16" => "glider",
        "AS20" => "glider",
        "AS21" => "glider",
        "AS22" => "glider",
        "AS24" => "glider",
        "AS25" => "glider",
        "AS26" => "glider",
        "AS28" => "glider",
        "AS29" => "glider",
        "AS30" => "glider",
        "AS31" => "glider",
        "DG80" => "glider",
        "DG1T" => "glider",
        "LS10" => "glider",
        "LS9" => "glider",
        "LS8" => "glider",
        "TS1J" => "glider",
        "PK20" => "glider",
        "LK17" => "glider",
        "LK19" => "glider",
        "LK20" => "glider",
        "ULAC" => "cessna",
        "EV97" => "cessna",
        "FDCT" => "cessna",
        "WT9" => "cessna",
        "PIVI" => "cessna",
        "FK9" => "cessna",
        "AVID" => "cessna",
        "NG5" => "cessna",
        "PNR3" => "cessna",
        "TL20" => "cessna",
        "SR20" => "cirrus_sr22",
        "SR22" => "cirrus_sr22",
        "S22T" => "cirrus_sr22",
        "VEZE" => "rutan_veze",
        "VELO" => "rutan_veze",
        "PRTS" => "rutan_veze",
        "PA24" => "pa24",
        "GND" => "ground_unknown",
        "GRND" => "ground_unknown",
        "SERV" => "ground_service",
        "EMER" => "ground_emergency",
        "TWR" => "ground_tower",
    };

    // Category -> icon shape key, from adsb_category_to_icon.csv, fallback tier when typeCode misses TYPE_TO_ICON. C4/C5 aren't in that CSV (only C3) - reuse the tower icon.
    private const CATEGORY_TO_ICON as Dictionary<String, String> = {
        "A1" => "cessna",
        "A2" => "jet_swept",
        "A3" => "airliner",
        "A4" => "airliner",
        "A5" => "heavy_2e",
        "A6" => "hi_perf",
        "A7" => "helicopter",
        "B1" => "glider",
        "B2" => "balloon",
        "B4" => "cessna",
        "B6" => "uav",
        "C0" => "ground_unknown",
        "C1" => "ground_emergency",
        "C2" => "ground_service",
        "C3" => "ground_tower",
        "C4" => "ground_tower",
        "C5" => "ground_tower",
    };

    // TYPE_TO_ICON's source CSV has real gaps for 767/787/Dash-8/ATR (see icon_rendering_history memory) - patched by prefix.
    private const TYPE_PREFIX_SUPPLEMENT as Array<[String, String]> = [
        ["B76", "heavy_2e"],
        ["B78", "heavy_2e"],
        ["DH8", "twin_large"],
        ["AT4", "twin_large"],
        ["AT7", "twin_large"],
    ] as Array<[String, String]>;

    private function _matchesType(
        typeCode as String?,
        list as Array<String>
    ) as Boolean {
        if (typeCode == null) {
            return false;
        }
        for (var i = 0; i < list.size(); i++) {
            if ((typeCode as String).equals(list[i])) {
                return true;
            }
        }
        return false;
    }

    private function _startsWith(s as String, prefix as String) as Boolean {
        return (
            s.length() >= prefix.length() &&
            s.substring(0, prefix.length()).equals(prefix)
        );
    }

    // Missing category is the norm both for older/cheaper GA transponders (correlates with small aircraft) and for large military transports (correlates with genuinely massive ones) - not a single-direction bias.
    private function _effectiveCategory(ac as Aircraft) as String {
        var cat = ac.category;
        if (cat != null) {
            return cat as String;
        }
        if (_matchesType(ac.typeCode, SUPER_HEAVY_TYPE_CODES)) {
            return "A5";
        }
        return _matchesType(ac.typeCode, LARGE_TYPE_CODES) ? "A3" : "A1";
    }

    // typeCode exact match, then prefix supplement, then category (covers ground vehicles/obstacles and helicopter bodies too, no separate branches needed) - else "unknown".
    private function _shapeKeyForAircraft(ac as Aircraft) as String {
        var t = ac.typeCode;
        if (t != null) {
            var exact = TYPE_TO_ICON[t as String];
            if (exact != null) {
                return exact as String;
            }
            for (var i = 0; i < TYPE_PREFIX_SUPPLEMENT.size(); i++) {
                var rule = TYPE_PREFIX_SUPPLEMENT[i];
                if (_startsWith(t as String, rule[0])) {
                    return rule[1];
                }
            }
        }
        var byCategory = CATEGORY_TO_ICON[_effectiveCategory(ac)];
        return byCategory != null ? byCategory as String : "unknown";
    }

    // Rotorcraft (A7) has no size signal in the category, so that shape stays fixed.
    private function _sizeScaleForAircraft(ac as Aircraft) as Float {
        var cat = _effectiveCategory(ac);
        if (cat.equals("A1")) {
            return 0.7;
        }
        if (cat.equals("A2")) {
            return 0.85;
        }
        if (cat.equals("A3")) {
            return 1.1;
        }
        if (cat.equals("A4")) {
            return 1.15;
        }
        if (cat.equals("A5")) {
            return 1.3;
        }
        return 1.0;
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

    private const LABEL_OVERLAP_MARGIN_PX = 4;
    private const LABEL_LINE_GAP_PX = 2;
    // Scaled by aircraft size like the reticle/icon, with enough margin to clear SELECTION_BRACKET_HALF at every size tier.
    private const LABEL_VOFFSET_BASE = 18.0;

    // Two rows (callsign / speed+altitude) instead of one wide line - narrower footprint, fewer overlap hides. No background rect - reads better floating directly over the radar, per-field colored the same way the compact/full detail views already color these same fields (not one flat aircraft-color line).
    private function _drawAircraftLabel(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        isSelected as Boolean
    ) as Void {
        var lines = _buildLabelLines(ac);
        var top = lines[0] as Array<[String, Number]>;
        var bottom = lines[1] as Array<[String, Number]>;
        if (top.size() == 0 && bottom.size() == 0) {
            return;
        }

        var topW = top.size() > 0 ? _segmentedLineWidth(dc, top) : 0;
        var bottomW = bottom.size() > 0 ? _segmentedLineWidth(dc, bottom) : 0;
        var lineH = dc.getTextDimensions("Ag", _fontTiny)[1];

        var width = topW > bottomW ? topW : bottomW;
        var height = 0;
        if (top.size() > 0) {
            height += lineH;
        }
        if (bottom.size() > 0) {
            height += lineH;
        }
        if (top.size() > 0 && bottom.size() > 0) {
            height += LABEL_LINE_GAP_PX;
        }

        var textY =
            y + (LABEL_VOFFSET_BASE * _sizeScaleForAircraft(ac)).toNumber();
        var rect =
            [
                x - width / 2 - LABEL_OVERLAP_MARGIN_PX,
                textY - LABEL_OVERLAP_MARGIN_PX,
                x + width / 2 + LABEL_OVERLAP_MARGIN_PX,
                textY + height + LABEL_OVERLAP_MARGIN_PX,
            ] as [Number, Number, Number, Number];
        // Selection overrides the declutter-by-overlap check too, same as the icon/reticle/trail filters above.
        if (!isSelected && _overlapsReserved(ac.hex, rect)) {
            return;
        }
        _reserveRect(ac.hex, rect);

        var lineY = textY;
        if (top.size() > 0) {
            _drawSegmentedLine(dc, x, lineY, top);
            lineY += lineH + LABEL_LINE_GAP_PX;
        }
        if (bottom.size() > 0) {
            _drawSegmentedLine(dc, x, lineY, bottom);
        }
    }

    private function _segmentedLineWidth(
        dc as Dc,
        segments as Array<[String, Number]>
    ) as Number {
        var totalW = -SEGMENT_GAP_PX;
        for (var i = 0; i < segments.size(); i++) {
            totalW +=
                dc.getTextDimensions(segments[i][0] as String, _fontTiny)[0] +
                SEGMENT_GAP_PX;
        }
        return totalW;
    }

    // Same colors as the equivalent fields in the compact/full detail views (callsign=aircraft color, speed=yellow, altitude=blue) - a label is just the at-a-glance version of the same data, so it should read consistently rather than as one flat aircraft-color line.
    private function _buildLabelLines(
        ac as Aircraft
    ) as [Array<[String, Number]>, Array<[String, Number]>] {
        var top = [] as Array<[String, Number]>;
        if (Settings.isLabelFieldEnabled("callsign")) {
            var cs = ac.flight;
            if (cs != null && cs.length() > 0) {
                top.add([cs as String, _colorForAircraft(ac)]);
            }
        }

        var bottom = [] as Array<[String, Number]>;
        if (Settings.isLabelFieldEnabled("speed") && ac.gs != null) {
            bottom.add([
                _formatSpeedKt((ac.gs as Float).toNumber()),
                COLOR_SPEED,
            ]);
        }
        if (Settings.isLabelFieldEnabled("altitude")) {
            if (ac.onGround) {
                bottom.add(["GND", COLOR_ALT]);
            } else if (ac.altBaro != null) {
                bottom.add([
                    _formatAltitude(ac.altBaro as Number),
                    COLOR_ALT,
                ]);
            }
        }

        return [top, bottom] as [
            Array<[String, Number]>,
            Array<[String, Number]>,
        ];
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

        var panelH = lines.size() * DETAIL_PANEL_LINE_HEIGHT + 8;
        var panelY = h - panelH;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        // Starts one row below panelY, not at it - leaves the boundary-ring pixel at panelY itself unerased, so the border line drawn there (_drawPanelBorder) sits on top of it seamlessly instead of on bare black. The top panel's own fillRectangle(0, 0, w, panelH) already has this property for free (it stops one row short of its own border line at panelH); this mirrors that on the bottom edge.
        dc.fillRectangle(0, panelY + 1, dc.getWidth(), panelH - 1);

        for (var i = 0; i < lines.size(); i++) {
            _drawSegmentedLine(
                dc,
                cx,
                panelY + 4 + i * DETAIL_PANEL_LINE_HEIGHT,
                lines[i] as Array<[String, Number]>
            );
        }

        _drawPanelBorder(dc, panelY, cx, cy, radiusPx);
        _drawChevronUp(dc, cx, panelY - CHEVRON_MARGIN_PX, CHEVRON_SIZE_PX);
    }

    // 0 when nothing is selected, so callers can treat "no panel" and "empty panel" the same.
    private function _detailPanelHeight(ac as Aircraft) as Number {
        var lines = _buildDetailLines(ac);
        return lines.size() == 0
            ? 0
            : lines.size() * DETAIL_PANEL_LINE_HEIGHT + 8;
    }

    private const CHEVRON_MARGIN_PX = 20;
    private const CHEVRON_SIZE_PX = 7;
    // Extra tap area above the panel's own top edge, covering the chevron drawn there - lets the chevron itself feel tappable, not just the panel body.
    private const CHEVRON_TAP_MARGIN_PX = 28;

    // "There's more above" - visually extends the panel into the full-detail view opened by tapping it. Mirrors _drawMinusHint/_drawMenuHint's plain-line style, no font glyph involved. Full white, not COLOR_TEXT - it's an affordance, not body text, so it should read as brighter than the panel content around it.
    private function _drawChevronUp(
        dc as Dc,
        x as Number,
        y as Number,
        s as Number
    ) as Void {
        // Plain setColor, not _setSolidColor/setStroke - matches AircraftDetailView's own (confirmed working) down chevron exactly, rather than relying solely on the _setSolidColor alpha fix above.
        dc.setColor(COLORS[0], Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x - s, y + s, x, y);
        dc.drawLine(x, y, x + s, y + s);
    }

    private const SEGMENT_GAP_PX = 6;

    // Embedded in a segment string to mark where a code-drawn degree circle goes, same "°" isn't in the custom bitmap fonts fix used in AircraftDetailView - duplicated here since _drawSegmentedLine is this file's own equivalent of that view's value-segment drawing.
    private const DEGREE_MARK = "^";
    private const DEGREE_MARK_GAP_LEFT = 1;
    private const DEGREE_MARK_GAP_RIGHT = 2;
    private const DEGREE_MARK_R = 1;
    private const DEGREE_MARK_Y_OFFSET = 4;

    // Draws left-to-right segments as one horizontally-centered group, each in its own color.
    private function _drawSegmentedLine(
        dc as Dc,
        cx as Number,
        y as Number,
        segments as Array<[String, Number]>
    ) as Void {
        if (segments.size() == 0) {
            return;
        }
        var widths = [] as Array<Number>;
        var totalW = -SEGMENT_GAP_PX;
        for (var i = 0; i < segments.size(); i++) {
            var w = _segmentWidth(dc, segments[i][0] as String);
            widths.add(w);
            totalW += w + SEGMENT_GAP_PX;
        }

        var x = cx - totalW / 2;
        for (var i = 0; i < segments.size(); i++) {
            dc.setColor(segments[i][1] as Number, Graphics.COLOR_TRANSPARENT);
            _drawSegmentText(dc, x, y, segments[i][0] as String);
            x += (widths[i] as Number) + SEGMENT_GAP_PX;
        }
    }

    private function _segmentWidth(dc as Dc, text as String) as Number {
        var markIdx = text.find(DEGREE_MARK);
        if (markIdx == null) {
            return dc.getTextDimensions(text, _fontTiny)[0];
        }
        var idx = markIdx as Number;
        var before = text.substring(0, idx) as String;
        var after = text.substring(idx + 1, text.length()) as String;
        var beforeW = dc.getTextDimensions(before, _fontTiny)[0];
        var afterW =
            after.length() > 0 ? dc.getTextDimensions(after, _fontTiny)[0] : 0;
        var markW =
            DEGREE_MARK_GAP_LEFT +
            DEGREE_MARK_R * 2 +
            (after.length() > 0 ? DEGREE_MARK_GAP_RIGHT : 0);
        return beforeW + markW + afterW;
    }

    // Left-justified draw starting at x - the caller (_drawSegmentedLine) already handled centering the whole line and setting the color.
    private function _drawSegmentText(
        dc as Dc,
        x as Number,
        y as Number,
        text as String
    ) as Void {
        var markIdx = text.find(DEGREE_MARK);
        if (markIdx == null) {
            dc.drawText(x, y, _fontTiny, text, Graphics.TEXT_JUSTIFY_LEFT);
            return;
        }

        var idx = markIdx as Number;
        var before = text.substring(0, idx) as String;
        var after = text.substring(idx + 1, text.length()) as String;
        dc.drawText(x, y, _fontTiny, before, Graphics.TEXT_JUSTIFY_LEFT);
        var beforeW = dc.getTextDimensions(before, _fontTiny)[0];
        var circleCx = x + beforeW + DEGREE_MARK_GAP_LEFT + DEGREE_MARK_R;
        dc.drawCircle(
            circleCx,
            y + DEGREE_MARK_R + DEGREE_MARK_Y_OFFSET,
            DEGREE_MARK_R
        );
        if (after.length() > 0) {
            dc.drawText(
                circleCx + DEGREE_MARK_R + DEGREE_MARK_GAP_RIGHT,
                y,
                _fontTiny,
                after,
                Graphics.TEXT_JUSTIFY_LEFT
            );
        }
    }

    // Deliberately curated, not exhaustive - tas/vert-rate/nav-target/non-emergency squawk moved to _buildFullDetailRows to keep this panel short.
    private function _buildDetailLines(
        ac as Aircraft
    ) as Array<Array<[String, Number]> > {
        var lines = [] as Array<Array<[String, Number]> >;

        var idSegs = [] as Array<[String, Number]>;
        idSegs.add([
            ac.flight != null && (ac.flight as String).length() > 0
                ? ac.flight as String
                : ac.hex,
            _colorForAircraft(ac),
        ]);
        if (ac.registration != null) {
            idSegs.add([ac.registration as String, COLOR_DETAIL_VALUE]);
        }
        var badgeParts = [] as Array<String>;
        if (ac.spi) {
            badgeParts.add("IDENT");
        }
        if (ac.alertFlag) {
            badgeParts.add("ALERT");
        }
        if (badgeParts.size() > 0) {
            idSegs.add([
                _join(badgeParts, " "),
                ac.isEmergency() ? COLOR_EMERGENCY : COLOR_WARN,
            ]);
        }
        lines.add(idSegs);

        var typeStr =
            ac.typeDesc != null
                ? ac.typeDesc as String
                : ac.typeCode != null
                  ? ac.typeCode as String
                  : "";
        if (typeStr.length() > 0) {
            lines.add(
                [[typeStr, COLOR_DETAIL_VALUE]] as Array<[String, Number]>
            );
        }

        var statSegs = [] as Array<[String, Number]>;
        if (ac.onGround) {
            statSegs.add(["GND", COLOR_ALT]);
        } else if (ac.altBaro != null) {
            statSegs.add([_formatAltitude(ac.altBaro as Number), COLOR_ALT]);
        }
        if (ac.gs != null) {
            statSegs.add([
                _formatSpeedKt((ac.gs as Float).toNumber()),
                COLOR_SPEED,
            ]);
        }
        if (ac.track != null) {
            statSegs.add([
                (ac.track as Float).toNumber().toString() + "^",
                COLOR_HDG,
            ]);
        }
        if (statSegs.size() > 0) {
            lines.add(statSegs);
        }

        // Emergency only - safety-critical, always worth surfacing without opening the full view.
        if (ac.isEmergency()) {
            var label =
                ac.squawk != null
                    ? "EMERG " + (ac.squawk as String)
                    : "EMERGENCY";
            lines.add([[label, COLOR_EMERGENCY]] as Array<[String, Number]>);
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
        lines.add(
            [[trackStatus, trackColor]] as Array<[String, Number]>
        );

        return lines;
    }

    // Adds a curated (not sequential-buffer) row: both cells paired if both exist, otherwise whichever one exists gets its own full-width row, otherwise nothing is added.
    private function _gridRow(
        rows as Array<Array<[String, String, Number]> >,
        cellA as [String, String, Number]?,
        cellB as [String, String, Number]?
    ) as Void {
        if (cellA != null && cellB != null) {
            rows.add([
                cellA as [String, String, Number],
                cellB as [String, String, Number],
            ]);
        } else if (cellA != null) {
            rows.add([cellA as [String, String, Number]]);
        } else if (cellB != null) {
            rows.add([cellB as [String, String, Number]]);
        }
    }

    // Everything the compact panel leaves out, for AircraftDetailView's scrollable grid. Deliberately curated, not a generic "pair everything sequentially" scheme - long identity text (type/operator) always gets its own full-width row, only genuinely short/similar stats share a compact 2-field row (AircraftDetailView draws every row as one centered inline line regardless of field count, so there's no separate font-size treatment to keep in sync here). Colors reuse the compact panel's own semantics (alt=blue, speed=yellow, hdg=cyan, grey=secondary, emergency=red) except grey, which uses the brighter COLOR_DETAIL_VALUE instead of COLOR_GRID_LABEL - this is a dedicated full screen, not a small chrome overlay. `^` embedded in a value string marks where AircraftDetailView should draw a code-drawn degree circle instead of a "°" character - this app's custom bitmap fonts don't have that glyph baked in (see [[selection_declutter_history]]), same fix TerminalWatchface already uses (`_drawSmallTempNum`/`_glowCircle`).
    private function _buildFullDetailRows(
        ac as Aircraft
    ) as [Array<Array<[String, String, Number]> >, Number] {
        var rows = [] as Array<Array<[String, String, Number]> >;

        var regCell =
            ac.registration != null
                ? [
                    "Registration",
                    ac.registration as String,
                    COLOR_DETAIL_VALUE,
                  ] as [String, String, Number]
                : null;
        _gridRow(rows, regCell, [
            "Hex",
            ac.hex,
            COLOR_DETAIL_VALUE,
        ]);

        var typeStr = ac.typeDesc != null ? ac.typeDesc : ac.typeCode;
        var typeCell =
            typeStr != null
                ? ["Type", typeStr as String, COLOR_DETAIL_VALUE] as [
                    String,
                    String,
                    Number,
                  ]
                : null;
        var categoryCell =
            ac.category != null
                ? ["Category", ac.category as String, COLOR_DETAIL_VALUE] as [
                    String,
                    String,
                    Number,
                  ]
                : null;
        _gridRow(rows, typeCell, categoryCell);

        if (ac.operatorName != null) {
            rows.add([
                [
                    "Operator",
                    ac.operatorName as String,
                    COLOR_DETAIL_VALUE,
                ] as [String, String, Number],
            ]);
        }

        var altCell = null as [String, String, Number]?;
        if (ac.onGround) {
            altCell = ["Altitude", "GND", COLOR_ALT];
        } else if (ac.altBaro != null) {
            altCell = [
                "Altitude",
                _formatAltitude(ac.altBaro as Number),
                COLOR_ALT,
            ];
        }
        var vertRateCell = null as [String, String, Number]?;
        if (ac.vertRate != null) {
            var vr = ac.vertRate as Float;
            var climbing = vr > 0;
            var sign = climbing ? "+" : "";
            vertRateCell = [
                "Vertical Rate",
                sign + _formatVertRate(vr.toNumber()),
                climbing ? COLOR_SUCCESS : COLOR_WARN,
            ];
        }
        _gridRow(rows, altCell, vertRateCell);

        var gsCell =
            ac.gs != null
                ? [
                    "Ground Speed",
                    _formatSpeedKt((ac.gs as Float).toNumber()),
                    COLOR_SPEED,
                  ] as [String, String, Number]
                : null;
        var iasCell =
            ac.ias != null
                ? [
                    "IAS",
                    _formatSpeedKt(ac.ias as Number),
                    COLOR_SPEED,
                  ] as [String, String, Number]
                : null;
        _gridRow(rows, gsCell, iasCell);

        var tasCell =
            ac.tas != null
                ? [
                    "TAS",
                    _formatSpeedKt((ac.tas as Float).toNumber()),
                    COLOR_SPEED,
                  ] as [String, String, Number]
                : null;
        var machCell =
            ac.mach != null
                ? [
                    "Mach",
                    (ac.mach as Float).format("%.2f"),
                    COLOR_SPEED,
                  ] as [String, String, Number]
                : null;
        _gridRow(rows, tasCell, machCell);

        var emergency = ac.isEmergency();
        var hdgCell =
            ac.track != null
                ? [
                    "Heading",
                    (ac.track as Float).toNumber().toString() + "^",
                    COLOR_HDG,
                  ] as [String, String, Number]
                : null;
        var squawkCell =
            ac.squawk != null
                ? [
                    "Squawk",
                    ac.squawk as String,
                    emergency ? COLOR_EMERGENCY : COLOR_SQUAWK,
                  ] as [String, String, Number]
                : null;
        _gridRow(rows, hdgCell, squawkCell);

        var statusParts = [] as Array<String>;
        if (emergency) {
            statusParts.add("EMERGENCY");
        }
        if (ac.spi) {
            statusParts.add("IDENT");
        }
        if (ac.alertFlag) {
            statusParts.add("ALERT");
        }
        if (statusParts.size() > 0) {
            rows.add([
                [
                    "Status",
                    _join(statusParts, " "),
                    emergency ? COLOR_EMERGENCY : COLOR_WARN,
                ] as [String, String, Number],
            ]);
        }

        var selAltCell =
            ac.navAltitude != null
                ? [
                    "Selected Alt",
                    _formatAltitude(ac.navAltitude as Number),
                    COLOR_DETAIL_VALUE,
                  ] as [String, String, Number]
                : null;
        var selHdgCell =
            ac.navHeading != null
                ? [
                    "Selected Hdg",
                    (ac.navHeading as Float).toNumber().toString() + "^",
                    COLOR_DETAIL_VALUE,
                  ] as [String, String, Number]
                : null;
        _gridRow(rows, selAltCell, selHdgCell);

        if (ac.windDir != null && ac.windSpeed != null) {
            rows.add([
                [
                    "Wind",
                    (ac.windDir as Number).toString() +
                        "^ @ " +
                        _formatSpeedKt(ac.windSpeed as Number),
                    COLOR_DETAIL_VALUE,
                ] as [String, String, Number],
            ]);
        }

        var outTempCell =
            ac.outsideAirTemp != null
                ? [
                    "Outside Temp",
                    (ac.outsideAirTemp as Number).toString() + "^C",
                    COLOR_DETAIL_VALUE,
                  ] as [String, String, Number]
                : null;
        var totalTempCell =
            ac.totalAirTemp != null
                ? [
                    "Total Air Temp",
                    (ac.totalAirTemp as Number).toString() + "^C",
                    COLOR_DETAIL_VALUE,
                  ] as [String, String, Number]
                : null;
        _gridRow(rows, outTempCell, totalTempCell);

        rows.add([
            ["Route", "Loading...", COLOR_ROUTE_DIM] as [
                String,
                String,
                Number,
            ],
        ]);
        var routeIndex = rows.size() - 1;

        return [rows, routeIndex] as [
            Array<Array<[String, String, Number]> >,
            Number,
        ];
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
