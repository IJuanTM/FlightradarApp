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
    private var _selectedTrack as Array<[Float, Float]> = [];
    private var _trackFetchInFlight as Boolean = false;
    private var _trackFetchHex as String?;
    private var _trackHasHistory as Boolean = false;
    private var _selectedMissCount as Number = 0;
    private var _trackFetchRetried as Boolean = false;

    private var _manualFocus as [Float, Float]?;
    private var _dragStartCoords as [Number, Number]?;
    private var _dragLastCoords as [Number, Number]?;
    private var _dragCommitted as Boolean = false;
    private var _lastRadiusPx as Number = 1;
    // Timestamp-gated, not a plain flag - a standalone tap may never fire beginDrag on real hardware.
    private var _dragStopAtMs as Number?;
    private const TAP_SUPPRESS_WINDOW_MS = 300;
    // Caps continueDrag's redraw rate - unthrottled, it called requestUpdate on every raw mouse-move event.
    private var _lastDragRedrawMs as Number = 0;
    private const DRAG_REDRAW_INTERVAL_MS = 33;

    private var _pollTimer as Timer.Timer?;
    private var _ticksSincePoll as Number = 0;
    // Fast enough to read as spinning on a low-refresh watch display, without redrawing so often it hurts battery.
    private const ANIM_TICK_MS = 200;
    // 20deg/tick - the old 900ms (~80deg/tick) was too close to the 4-blade rotor's 90deg symmetry and looked like jitter, not spin (wagon-wheel aliasing).
    private const HELI_SPIN_PERIOD_MS = 3600;

    private var _noGpsText as String = "";
    private var _noSignalText as String = "";
    private var _tooBusyText as String = "";
    private var _fontSmall as Graphics.FontType = Graphics.FONT_SMALL;
    private var _fontTiny as Graphics.FontType = Graphics.FONT_XTINY;
    private var _client as AirplanesLiveClient = new AirplanesLiveClient();
    private var _openSky as OpenSkyClient = new OpenSkyClient();

    // Each entry is [normal, emergency-outline] - selection uses a reticle instead, not a bitmap variant.
    private var _iconBitmaps as
        Dictionary<String, Array<Graphics.BitmapType> > = {};

    public function initialize() {
        View.initialize();
    }

    public function onLayout(dc as Dc) as Void {
        _noGpsText = WatchUi.loadResource(Rez.Strings.NoGps) as String;
        _noSignalText = WatchUi.loadResource(Rez.Strings.NoSignal) as String;
        _tooBusyText = WatchUi.loadResource(Rez.Strings.TooBusy) as String;
        _fontSmall =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_SMALL) as
            Graphics.FontDefinition;
        _fontTiny =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_TINY) as
            Graphics.FontDefinition;
        _iconBitmaps = {
            "a0" => _loadIconSet(
                Rez.Drawables.AircraftA0,
                Rez.Drawables.AircraftA0Emg
            ),
            "a1" => _loadIconSet(
                Rez.Drawables.AircraftA1,
                Rez.Drawables.AircraftA1Emg
            ),
            "a2" => _loadIconSet(
                Rez.Drawables.AircraftA2,
                Rez.Drawables.AircraftA2Emg
            ),
            "a3" => _loadIconSet(
                Rez.Drawables.AircraftA3,
                Rez.Drawables.AircraftA3Emg
            ),
            "a4" => _loadIconSet(
                Rez.Drawables.AircraftA4,
                Rez.Drawables.AircraftA4Emg
            ),
            "a5" => _loadIconSet(
                Rez.Drawables.AircraftA5,
                Rez.Drawables.AircraftA5Emg
            ),
            "a6" => _loadIconSet(
                Rez.Drawables.AircraftA6,
                Rez.Drawables.AircraftA6Emg
            ),
            "vehicle" => _loadIconSet(
                Rez.Drawables.AircraftVehicle,
                Rez.Drawables.AircraftVehicleEmg
            ),
            "a320" => _loadIconSet(
                Rez.Drawables.AircraftA320,
                Rez.Drawables.AircraftA320Emg
            ),
            "a330" => _loadIconSet(
                Rez.Drawables.AircraftA330,
                Rez.Drawables.AircraftA330Emg
            ),
            "a340" => _loadIconSet(
                Rez.Drawables.AircraftA340,
                Rez.Drawables.AircraftA340Emg
            ),
            "a380" => _loadIconSet(
                Rez.Drawables.AircraftA380,
                Rez.Drawables.AircraftA380Emg
            ),
            "b737" => _loadIconSet(
                Rez.Drawables.AircraftB737,
                Rez.Drawables.AircraftB737Emg
            ),
            "b747" => _loadIconSet(
                Rez.Drawables.AircraftB747,
                Rez.Drawables.AircraftB747Emg
            ),
            "b767" => _loadIconSet(
                Rez.Drawables.AircraftB767,
                Rez.Drawables.AircraftB767Emg
            ),
            "b777" => _loadIconSet(
                Rez.Drawables.AircraftB777,
                Rez.Drawables.AircraftB777Emg
            ),
            "b787" => _loadIconSet(
                Rez.Drawables.AircraftB787,
                Rez.Drawables.AircraftB787Emg
            ),
            "c130" => _loadIconSet(
                Rez.Drawables.AircraftC130,
                Rez.Drawables.AircraftC130Emg
            ),
            "cessna" => _loadIconSet(
                Rez.Drawables.AircraftCessna,
                Rez.Drawables.AircraftCessnaEmg
            ),
            "crjx" => _loadIconSet(
                Rez.Drawables.AircraftCrjx,
                Rez.Drawables.AircraftCrjxEmg
            ),
            "dh8a" => _loadIconSet(
                Rez.Drawables.AircraftDh8a,
                Rez.Drawables.AircraftDh8aEmg
            ),
            "e195" => _loadIconSet(
                Rez.Drawables.AircraftE195,
                Rez.Drawables.AircraftE195Emg
            ),
            "erj" => _loadIconSet(
                Rez.Drawables.AircraftErj,
                Rez.Drawables.AircraftErjEmg
            ),
            "f100" => _loadIconSet(
                Rez.Drawables.AircraftF100,
                Rez.Drawables.AircraftF100Emg
            ),
            "fa7x" => _loadIconSet(
                Rez.Drawables.AircraftFa7x,
                Rez.Drawables.AircraftFa7xEmg
            ),
            "glf5" => _loadIconSet(
                Rez.Drawables.AircraftGlf5,
                Rez.Drawables.AircraftGlf5Emg
            ),
            "learjet" => _loadIconSet(
                Rez.Drawables.AircraftLearjet,
                Rez.Drawables.AircraftLearjetEmg
            ),
            "md11" => _loadIconSet(
                Rez.Drawables.AircraftMd11,
                Rez.Drawables.AircraftMd11Emg
            ),
        };
    }

    private function _loadIconSet(
        normal as ResourceId,
        emg as ResourceId
    ) as Array<Graphics.BitmapType> {
        return [
            WatchUi.loadResource(normal) as Graphics.BitmapType,
            WatchUi.loadResource(emg) as Graphics.BitmapType,
        ];
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
        if (
            _ticksSincePoll * ANIM_TICK_MS >=
            POLL_MS_BY_ZOOM[Settings.zoomIndex]
        ) {
            _ticksSincePoll = 0;
            _fetchNow();
        }

        if (_fetchInFlight && !_fetchTimedOutDisplay) {
            WatchUi.requestUpdate();
            return;
        }

        // Only redraws for the spin's sake if a rotorcraft is actually on screen.
        for (var i = 0; i < _aircraft.size(); i++) {
            if (_aircraft[i].isHelicopter()) {
                WatchUi.requestUpdate();
                return;
            }
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
        _fetchSelectedTrack();
        WatchUi.requestUpdate();
    }

    public function deselectAircraft() as Void {
        _selectedHex = null;
        _selectedTrack = [];
        _selectedMissCount = 0;
        WatchUi.requestUpdate();
    }

    // Freezes the camera at its current position first, so tapping empty space doesn't also recenter to self.
    public function deselectAircraftKeepView() as Void {
        if (_selectedHex != null) {
            _manualFocus = _focusPoint();
        }
        deselectAircraft();
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
        points as Array<[Float, Float]>,
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
                        deselectAircraft();
                    }
                } else {
                    _selectedMissCount = 0;
                    _appendLiveTrackPoint(selectedAc as Aircraft);
                }
            }
        }

        WatchUi.requestUpdate();
    }

    private function _appendLiveTrackPoint(ac as Aircraft) as Void {
        _selectedTrack.add([ac.lat, ac.lon]);
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
        var topPanelH = _topPanelHeight();

        if (!_hasFix or _centerLat == null or _centerLon == null) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
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
        if (Settings.showScaleBar) {
            _drawScaleBar(dc, cx, cy, radiusPx, radiusKm);
        }
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
                    _drawRingLabel(dc, cx, cy, ringPx, ringKm, topPanelH);
                    ringKm += stepKm;
                }
            }
        }
        // Boundary ring drawn more solid, like a scope's detection edge - always shown, marks the zoom radius itself.
        dc.setStroke(_withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawCircle(cx, cy, radiusPx);
        _drawRingLabel(dc, cx, cy, radiusPx, radiusKm, topPanelH);

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

    // Upper-right (45deg) so it doesn't collide with the top panel or the scale bar at bottom-center.
    private function _drawRingLabel(
        dc as Dc,
        cx as Number,
        cy as Number,
        ringPx as Number,
        ringKm as Float,
        topPanelH as Number
    ) as Void {
        var theta = Math.toRadians(45.0);
        var x = cx + (ringPx * Math.sin(theta)).toNumber();
        var y = cy - (ringPx * Math.cos(theta)).toNumber();
        if (y < topPanelH + 10) {
            return;
        }
        _drawGridLabel(dc, x, y, _formatKm(ringKm));
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

    // Real round-number distance sized to fit the available width - not a fixed per-zoom value that can disappear.
    private const SCALE_BAR_MAX_WIDTH_FRACTION = 0.7;

    private function _drawScaleBar(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float
    ) as Void {
        var y0 = cy + radiusPx - 24;
        var dy = (y0 - cy).abs();
        if (dy >= radiusPx) {
            return;
        }
        var halfW = _chordHalfExtent(radiusPx, dy);

        var maxBarPx = halfW * 2 * SCALE_BAR_MAX_WIDTH_FRACTION;
        var maxKm = (maxBarPx * radiusKm) / radiusPx;
        var stepKm = _niceKmStep(maxKm);
        var stepPx = _round((stepKm * radiusPx) / radiusKm);
        if (stepPx < 8) {
            return;
        }

        var label = _formatKm(stepKm);
        var textDims = dc.getTextDimensions(label, _fontTiny);
        if (stepPx > halfW * 2 || textDims[0] > halfW * 2) {
            return;
        }
        var x0 = cx - stepPx / 2;
        var x1 = cx + stepPx / 2;
        var textCy = y0 - 3 - 2 - textDims[1] / 2;

        var textPadX = 3;
        var textPadY = 1;
        var linePad = 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(
            cx - textDims[0] / 2 - textPadX,
            textCy - textDims[1] / 2 - textPadY,
            textDims[0] + textPadX * 2,
            textDims[1] + textPadY * 2
        );
        dc.fillRectangle(
            x0 - linePad,
            y0 - 3 - linePad,
            x1 - x0 + linePad * 2,
            6 + linePad * 2
        );

        _setSolidColor(dc, COLOR_TEXT);
        dc.drawText(
            cx,
            textCy,
            _fontTiny,
            label,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
        dc.drawLine(x0, y0, x1, y0);
        dc.drawLine(x0, y0 - 3, x0, y0 + 3);
        dc.drawLine(x1, y0 - 3, x1, y0 + 3);
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

    // Zoom in (KEY_UP).
    private function _drawPlusHint(dc as Dc, x as Number, y as Number) as Void {
        _setSolidColor(dc, COLOR_TEXT);
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
        _setSolidColor(dc, COLOR_TEXT);
        var s = 6;
        dc.drawLine(x - s, y, x + s, y);
    }

    // Menu (KEY_ENTER/KEY_MENU).
    private function _drawMenuHint(dc as Dc, x as Number, y as Number) as Void {
        _setSolidColor(dc, COLOR_TEXT);
        var s = 4;
        dc.drawLine(x - s, y - 3, x + s, y - 3);
        dc.drawLine(x - s, y, x + s, y);
        dc.drawLine(x - s, y + 3, x + s, y + 3);
    }

    // Recenter (KEY_ESC).
    private function _drawRecenterHint(
        dc as Dc,
        x as Number,
        y as Number
    ) as Void {
        _setSolidColor(dc, COLOR_TEXT);
        dc.drawCircle(x, y, 6);
        dc.fillCircle(x, y, 1);
    }

    // Zoom radius is labeled on the boundary ring instead (see _drawChrome); "No Signal" takes that old top-line slot here.
    private function _topPanelLines() as Array<[String, Number]> {
        var lines = [] as Array<[String, Number]>;
        if (_fetchTimedOutDisplay) {
            lines.add([_noSignalText, Graphics.COLOR_RED]);
        } else if (!_lastFetchOk) {
            lines.add([
                _lastFetchTooMuchData ? _tooBusyText : _noSignalText,
                Graphics.COLOR_RED,
            ]);
        }
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
        dc.setStroke(_withAlpha(COLOR_RING, COLOR_RING_ALPHA));
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
                    _formatLat(lat, false)
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
                _drawGridLabel(dc, pt[0], labelY, _formatLon(lon, false));
            }
        }
    }

    private function _drawGridLabel(
        dc as Dc,
        x as Number,
        y as Number,
        text as String
    ) as Void {
        var dims = dc.getTextDimensions(text, _fontTiny);
        var padX = 3;
        var padY = 1;
        var boxW = dims[0] + padX * 2;
        var boxH = dims[1] + padY * 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x - boxW / 2, y - boxH / 2, boxW, boxH);

        dc.setColor(COLOR_GRID_LABEL, Graphics.COLOR_TRANSPARENT);
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
        dc.setStroke(_withAlpha(color, 0xff));
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
                if (Settings.hideGroundVehicles && isGroundVehicle) {
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

            if (isSelected) {
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

            // Biggest halo first so both can show as concentric outlines when an emergency aircraft is also selected.
            if (ac.isEmergency()) {
                _drawIconHalo(
                    dc,
                    pos[0],
                    pos[1],
                    ac,
                    COLOR_EMERGENCY,
                    VARIANT_EMERGENCY
                );
            }
            _drawAircraftIcon(dc, pos[0], pos[1], ac);
            _drawVertRateChevron(dc, pos[0], pos[1], ac);

            // Reserved for every aircraft, ahead of the label pass - a label must never cover any icon or clip any climb/descend chevron, not just the selected one's.
            _reserveRect(ac.hex, _iconRect(pos[0], pos[1], ac));
            var chevronRect = _chevronRect(pos[0], pos[1], ac);
            if (chevronRect != null) {
                _reserveRect(
                    ac.hex,
                    chevronRect as [Number, Number, Number, Number]
                );
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
            _drawIconHalo(dc, x, y, ac, COLOR_EMERGENCY, VARIANT_EMERGENCY);
        }
        _drawAircraftIcon(dc, x, y, ac);
        _drawVertRateChevron(dc, x, y, ac);
        _drawSelectionReticle(dc, x, y, ac);
    }

    // OpenSky history fetched once on selection, not app-accumulated.
    private function _drawSelectedTrail(
        dc as Dc,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        color as Number
    ) as Void {
        if (_selectedTrack.size() < 2) {
            return;
        }
        dc.setStroke(_withAlpha(color, COLOR_TRAIL_ALPHA));
        var prev = null as Array<Number>?;
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
            if (prev != null) {
                dc.drawLine(
                    (prev as Array<Number>)[0],
                    (prev as Array<Number>)[1],
                    screen[0],
                    screen[1]
                );
            }
            prev = screen;
        }
    }

    private const GROUNDED_DIM_FACTOR = 0.45;
    // A position this old hasn't actually moved across several poll cycles - likely a fringe-of-coverage ghost.
    private const STALE_POSITION_SEC = 15.0;
    private const STALE_DIM_FACTOR = 0.55;
    // 96px canvas (64px art + padding for dilation headroom), scaled to ~22px on screen at the 1.0 size tier.
    private const ICON_BASE_SCALE = 0.34;
    private const ICON_SRC_SIZE = 96.0;
    private const VARIANT_NORMAL = 0;
    private const VARIANT_EMERGENCY = 1;
    private const ICON_RECT_MARGIN = 2;

    // Half-diagonal (source-canvas px, scale 1.0) of each shape's actual rendered art bbox - every icon shares the same 64px height by convention, but width varies a lot per shape (crjx ~40px, cessna ~91px), so a single generic canvas-based extent visibly under/overshoots depending on which shape an aircraft got.
    private const ICON_HALF_DIAGONAL as Dictionary<String, Float> = {
        "a0" => 42.5,
        "a1" => 43.9,
        "a2" => 43.9,
        "a3" => 42.5,
        "a4" => 42.5,
        "a5" => 42.5,
        "a6" => 38.8,
        "vehicle" => 46.3,
        "a320" => 43.5,
        "a330" => 45.3,
        "a340" => 44.6,
        "a380" => 44.9,
        "b737" => 43.9,
        "b747" => 41.9,
        "b767" => 45.3,
        "b777" => 44.2,
        "b787" => 44.6,
        "c130" => 53.2,
        "cessna" => 55.6,
        "crjx" => 37.7,
        "dh8a" => 48.9,
        "e195" => 43.2,
        "erj" => 39.4,
        "f100" => 40.6,
        "fa7x" => 48.5,
        "glf5" => 43.2,
        "learjet" => 43.2,
        "md11" => 41.5,
    };

    // Helicopters use their own halo radius (a vector icon, not the bitmap canvas) - covers the emergency halo too, drawn at the same fixed size.
    private function _iconHalfExtent(ac as Aircraft) as Number {
        if (ac.isHelicopter()) {
            return HELI_HALO_RADIUS;
        }
        var diag = ICON_HALF_DIAGONAL[_shapeKeyForAircraft(ac)];
        var srcHalf = diag != null ? diag as Float : 42.5;
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

    private function _drawAircraftIcon(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var color = _colorForAircraft(ac);
        if (ac.onGround) {
            color = _dimColor(color, GROUNDED_DIM_FACTOR);
        }
        var age = ac.positionAgeSec;
        if (age != null && (age as Float) >= STALE_POSITION_SEC) {
            color = _dimColor(color, STALE_DIM_FACTOR);
        }
        if (ac.isHelicopter()) {
            _drawHelicopterIcon(dc, x, y, ac, color);
            return;
        }
        _drawIconVariant(dc, x, y, ac, color, VARIANT_NORMAL);
    }

    // Draws a pre-dilated bitmap variant at the same position/scale, so the gap reads as an even outline.
    private function _drawIconHalo(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        color as Number,
        variant as Number
    ) as Void {
        if (ac.isHelicopter()) {
            _setSolidColor(dc, color);
            dc.drawCircle(x, y, HELI_HALO_RADIUS);
            return;
        }
        _drawIconVariant(dc, x, y, ac, color, variant);
    }

    private const HELI_HUB_R = 2;
    private const HELI_BLADE_LEN = 10.0;
    private const HELI_BLADE_WIDTH = 2;
    private const HELI_HALO_RADIUS = 18;
    private const HELI_TANDEM_OFFSET = 7;

    // Blade/hub count is a real, well-documented rotor-system fact per type, not a guess - unmatched types keep the default 4-blade look.
    private const HELI_TWO_BLADE_TYPES as Array<String> = [
        "R22",
        "R44",
        "R66",
        "B06",
    ];
    private const HELI_THREE_BLADE_TYPES as Array<String> = ["AS50", "EC30"];
    private const HELI_FIVE_BLADE_TYPES as Array<String> = [
        "S92",
        "EH01",
        "AW01",
    ];
    private const HELI_TANDEM_TYPES as Array<String> = ["H47", "H46"];

    private function _heliBladeCount(typeCode as String?) as Number {
        if (_matchesType(typeCode, HELI_TWO_BLADE_TYPES)) {
            return 2;
        }
        if (_matchesType(typeCode, HELI_THREE_BLADE_TYPES)) {
            return 3;
        }
        if (_matchesType(typeCode, HELI_FIVE_BLADE_TYPES)) {
            return 5;
        }
        return 4;
    }

    // Tandem types (Chinook/Sea Knight) get two hubs instead of blade-count variation - the fore/aft pair is the distinctive silhouette cue.
    private function _drawHelicopterIcon(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        color as Number
    ) as Void {
        var spinTheta =
            ((System.getTimer() % HELI_SPIN_PERIOD_MS).toFloat() /
                HELI_SPIN_PERIOD_MS) *
            2 *
            Math.PI;

        _setSolidColor(dc, color);

        if (_matchesType(ac.typeCode, HELI_TANDEM_TYPES)) {
            _drawRotorHub(dc, x, y - HELI_TANDEM_OFFSET, spinTheta, 4);
            _drawRotorHub(dc, x, y + HELI_TANDEM_OFFSET, spinTheta, 4);
            return;
        }
        _drawRotorHub(dc, x, y, spinTheta, _heliBladeCount(ac.typeCode));
    }

    private function _drawRotorHub(
        dc as Dc,
        x as Number,
        y as Number,
        spinTheta as Float,
        bladeCount as Number
    ) as Void {
        dc.fillCircle(x, y, HELI_HUB_R);

        dc.setPenWidth(HELI_BLADE_WIDTH);
        var step = (2 * Math.PI) / bladeCount;
        for (var i = 0; i < bladeCount; i++) {
            var theta = spinTheta + i * step;
            var bx = x + (HELI_BLADE_LEN * Math.cos(theta)).toNumber();
            var by = y + (HELI_BLADE_LEN * Math.sin(theta)).toNumber();
            dc.drawLine(x, y, bx, by);
        }
        dc.setPenWidth(1);
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

    // Rotated bitmap + AffineTransform, tinted via :tintColor - not a rotated fillPolygon.
    private function _drawIconVariant(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        color as Number,
        variant as Number
    ) as Void {
        var track = ac.track;
        var theta = track != null ? Math.toRadians(track) : 0.0;

        var scale = ICON_BASE_SCALE * _sizeScaleForAircraft(ac);
        var half = ICON_SRC_SIZE / 2.0;

        var tf = new Graphics.AffineTransform();
        tf.translate(x.toFloat(), y.toFloat());
        tf.rotate(theta);
        tf.scale(scale, scale);
        tf.translate(-half, -half);

        dc.drawBitmap2(0, 0, _bitmapForAircraft(ac, variant), {
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

    // Type-specific silhouette checked first, else falls back to the category-tier shape - color stays category-only regardless.
    private function _bitmapForAircraft(
        ac as Aircraft,
        variant as Number
    ) as Graphics.BitmapType {
        var set =
            _iconBitmaps[_shapeKeyForAircraft(ac)] as
            Array<Graphics.BitmapType>;
        return set[variant] as Graphics.BitmapType;
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

    private const CESSNA_TYPE_CODES as Array<String> = [
        "C150",
        "C152",
        "C162",
        "C170",
        "C172",
        "C175",
        "C177",
        "C180",
        "C182",
        "C185",
        "C205",
        "C206",
        "C207",
        "C210",
    ];

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

    // Prefix/exact-match table built from real ICAO type designators, not category - lets same-category aircraft (e.g. all A3 jets) get distinct silhouettes.
    private function _typeShapeOverride(typeCode as String?) as String? {
        if (typeCode == null) {
            return null;
        }
        var t = typeCode as String;
        if (_startsWith(t, "B73") || t.equals("B38M") || t.equals("B39M")) {
            return "b737";
        }
        if (_startsWith(t, "B74")) {
            return "b747";
        }
        if (_startsWith(t, "B76")) {
            return "b767";
        }
        if (_startsWith(t, "B77")) {
            return "b777";
        }
        if (_startsWith(t, "B78")) {
            return "b787";
        }
        if (_startsWith(t, "A32")) {
            return "a320";
        }
        if (_startsWith(t, "A33")) {
            return "a330";
        }
        if (_startsWith(t, "A34")) {
            return "a340";
        }
        if (_startsWith(t, "A38")) {
            return "a380";
        }
        // C-5 Galaxy/C-17 Globemaster share the same non-swept, high-wing, T-tail cargo-plane silhouette as the C-130, just far bigger - no dedicated asset, reuse it rather than fall back to a swept-wing airliner shape.
        if (_startsWith(t, "C13") || _startsWith(t, "C5") || t.equals("C17")) {
            return "c130";
        }
        if (_matchesType(t, CESSNA_TYPE_CODES)) {
            return "cessna";
        }
        if (_startsWith(t, "CRJ")) {
            return "crjx";
        }
        if (_startsWith(t, "DH8")) {
            return "dh8a";
        }
        if (_startsWith(t, "E19") || _startsWith(t, "E29")) {
            return "e195";
        }
        if (_startsWith(t, "E17") || _startsWith(t, "ERJ")) {
            return "erj";
        }
        if (t.equals("F100")) {
            return "f100";
        }
        if (_startsWith(t, "FA") || t.equals("F900") || t.equals("F2TH")) {
            return "fa7x";
        }
        if (
            _startsWith(t, "GLF") ||
            t.equals("G450") ||
            t.equals("G550") ||
            t.equals("G650") ||
            t.equals("G280")
        ) {
            return "glf5";
        }
        if (_startsWith(t, "LJ")) {
            return "learjet";
        }
        if (t.equals("MD11")) {
            return "md11";
        }
        return null;
    }

    // Never called for helicopters - _drawAircraftIcon/_drawIconHalo branch to the vector heli icon first.
    private function _shapeKeyForAircraft(ac as Aircraft) as String {
        var override = _typeShapeOverride(ac.typeCode);
        if (override != null) {
            return override as String;
        }
        if (ac.isGroundVehicle()) {
            return "vehicle";
        }
        var cat = _effectiveCategory(ac);
        if (cat.equals("A1")) {
            return "a1";
        }
        if (cat.equals("A2")) {
            return "a2";
        }
        if (cat.equals("A3")) {
            return "a3";
        }
        if (cat.equals("A4")) {
            return "a4";
        }
        if (cat.equals("A5")) {
            return "a5";
        }
        if (cat.equals("A6")) {
            return "a6";
        }
        return "a0";
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

    // Two rows (callsign / speed+altitude) instead of one wide line - narrower footprint, fewer overlap hides.
    private function _drawAircraftLabel(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft,
        isSelected as Boolean
    ) as Void {
        var lines = _buildLabelLines(ac);
        var top = lines[0];
        var bottom = lines[1];
        if (top.length() == 0 && bottom.length() == 0) {
            return;
        }

        var topDims =
            top.length() > 0 ? dc.getTextDimensions(top, _fontTiny) : null;
        var bottomDims =
            bottom.length() > 0
                ? dc.getTextDimensions(bottom, _fontTiny)
                : null;

        var width = 0;
        var height = 0;
        if (topDims != null) {
            width = topDims[0];
            height += topDims[1];
        }
        if (bottomDims != null) {
            if (bottomDims[0] > width) {
                width = bottomDims[0];
            }
            height += bottomDims[1];
        }
        if (topDims != null && bottomDims != null) {
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
        if (topDims != null) {
            _drawLabelLineBg(dc, x, lineY, topDims);
            dc.setColor(_colorForAircraft(ac), Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, lineY, _fontTiny, top, Graphics.TEXT_JUSTIFY_CENTER);
            lineY += topDims[1] + LABEL_LINE_GAP_PX;
        }
        if (bottomDims != null) {
            _drawLabelLineBg(dc, x, lineY, bottomDims);
            dc.setColor(_colorForAircraft(ac), Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                x,
                lineY,
                _fontTiny,
                bottom,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }
    }

    private const LABEL_BG_PAD_X = 3;
    private const LABEL_BG_PAD_Y = 1;

    // One backing rect per line, sized to that line's own text only - not one block behind the whole label.
    private function _drawLabelLineBg(
        dc as Dc,
        x as Number,
        lineY as Number,
        dims as Array<Number>
    ) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(
            x - dims[0] / 2 - LABEL_BG_PAD_X,
            lineY - LABEL_BG_PAD_Y,
            dims[0] + LABEL_BG_PAD_X * 2,
            dims[1] + LABEL_BG_PAD_Y * 2
        );
    }

    private function _buildLabelLines(ac as Aircraft) as [String, String] {
        var top = "";
        if (Settings.isLabelFieldEnabled("callsign")) {
            var cs = ac.flight;
            if (cs != null && cs.length() > 0) {
                top = cs as String;
            }
        }

        var bottomParts = [] as Array<String>;
        if (Settings.isLabelFieldEnabled("speed") && ac.gs != null) {
            bottomParts.add((ac.gs as Float).toNumber().toString() + "kt");
        }
        if (Settings.isLabelFieldEnabled("altitude")) {
            if (ac.onGround) {
                bottomParts.add("GND");
            } else if (ac.altBaro != null) {
                bottomParts.add(
                    "FL" + ((ac.altBaro as Number) / 100).format("%03d")
                );
            }
        }

        return [top, _join(bottomParts, " ")] as [String, String];
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
        dc.fillRectangle(0, panelY, dc.getWidth(), panelH);

        for (var i = 0; i < lines.size(); i++) {
            var line = lines[i];
            dc.setColor(line[1] as Number, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                panelY + 4 + i * DETAIL_PANEL_LINE_HEIGHT,
                _fontTiny,
                line[0] as String,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        _drawPanelBorder(dc, panelY, cx, cy, radiusPx);
    }

    // 0 when nothing is selected, so callers can treat "no panel" and "empty panel" the same.
    private function _detailPanelHeight(ac as Aircraft) as Number {
        var lines = _buildDetailLines(ac);
        return lines.size() == 0
            ? 0
            : lines.size() * DETAIL_PANEL_LINE_HEIGHT + 8;
    }

    private function _buildDetailLines(
        ac as Aircraft
    ) as Array<[String, Number]> {
        var lines = [] as Array<[String, Number]>;

        var idParts = [] as Array<String>;
        idParts.add(
            ac.flight != null && (ac.flight as String).length() > 0
                ? ac.flight as String
                : ac.hex
        );
        if (ac.registration != null) {
            idParts.add(ac.registration as String);
        }
        lines.add([_join(idParts, " "), _colorForAircraft(ac)]);

        var typeStr =
            ac.typeDesc != null
                ? ac.typeDesc as String
                : ac.typeCode != null
                  ? ac.typeCode as String
                  : "";
        if (typeStr.length() > 0) {
            lines.add([typeStr, COLOR_GRID_LABEL]);
        }

        var statParts = [] as Array<String>;
        if (ac.onGround) {
            statParts.add("GND");
        } else if (ac.altBaro != null) {
            statParts.add("FL" + ((ac.altBaro as Number) / 100).format("%03d"));
        }
        if (ac.gs != null) {
            statParts.add((ac.gs as Float).toNumber().toString() + "kt");
        }
        if (ac.track != null) {
            statParts.add("hdg " + (ac.track as Float).toNumber().toString());
        }
        var statLine = _join(statParts, " ");
        if (statLine.length() > 0) {
            lines.add([statLine, COLOR_TEXT]);
        }

        var statParts2 = [] as Array<String>;
        if (ac.tas != null) {
            statParts2.add("tas" + (ac.tas as Float).toNumber().toString());
        }
        var vr = ac.vertRate;
        if (vr != null && (vr as Float).abs() >= VERT_RATE_THRESHOLD_FPM) {
            var sign = (vr as Float) > 0 ? "+" : "";
            statParts2.add(sign + (vr as Float).toNumber().toString() + "fpm");
        }
        var emergency = ac.isEmergency();
        if (ac.squawk != null) {
            statParts2.add(
                (emergency ? "EMERG " : "sq") + (ac.squawk as String)
            );
        }
        var statLine2 = _join(statParts2, " ");
        if (statLine2.length() > 0) {
            lines.add([statLine2, emergency ? COLOR_EMERGENCY : COLOR_TEXT]);
        }

        // What the autopilot is set to do next (MCP/FMS target), not the aircraft's current state.
        var navParts = [] as Array<String>;
        if (ac.navAltitude != null) {
            navParts.add(
                "sel FL" + ((ac.navAltitude as Number) / 100).format("%03d")
            );
        }
        if (ac.navHeading != null) {
            navParts.add(
                "hdg " + (ac.navHeading as Float).toNumber().toString()
            );
        }
        var navLine = _join(navParts, " ");
        if (navLine.length() > 0) {
            lines.add([navLine, COLOR_GRID_LABEL]);
        }

        // Blank (not omitted) mid-fetch, so the panel height doesn't shift as a fetch starts/stops.
        var trackStatus = "";
        if (_trackFetchInFlight) {
            trackStatus = "loading track...";
        } else if (!_trackHasHistory) {
            trackStatus = "no track history";
        }
        lines.add([trackStatus, COLOR_GRID_LABEL]);

        return lines;
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
}
