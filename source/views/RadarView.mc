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

class RadarView extends WatchUi.View {
    // Multiplies the zoom's poll interval in battery saver mode - fewer fetches, not a different schedule.
    private const BATTERY_SAVER_MULTIPLIER = 3;
    // 4 gives 1/2/3/4, 2/4/6/8, 5/10/15/20, 10/20/30/40 - 3 would give an ugly 3/6/9 at 10km.
    private const RING_TARGET_COUNT = 4;
    // Wider than the icon - real taps land less precisely than a mouse click.
    private const HIT_RADIUS_PX = 24;

    private var _charW as Number = 8;
    private var _charH as Number = 14;
    private var _edgeMargin as Number = 20;
    private var _gridLabelInset as Number = 22;
    private var _topPanelLineHeight as Number = 18;
    private var _detailPanelLineHeight as Number = 18;

    // Persisted on real app exit so a future cold app-open (currentLocation gone stale) still has a seed.
    private const STORAGE_KEY_LAT = "lastKnownLat";
    private const STORAGE_KEY_LON = "lastKnownLon";
    private const STORAGE_KEY_TS = "lastKnownTs";
    // Past this, a stored fix is more likely hours stale than near the user - better to wait for a real fix.
    private const MAX_STORED_POSITION_AGE_SEC = 900;

    private var _userLat as Float?;
    private var _userLon as Float?;
    private var _hasFix as Boolean = false;
    // [lat, lon, epochSec] of the last real GPS fix - kept apart from _userLat/Lon, which fallback seeds also overwrite.
    private var _liveFix as [Float, Float, Number]?;

    private var _aircraft as Array<Aircraft> = [];
    private var _aircraftByHex as Dictionary<String, Aircraft> = {};
    private var _lastFeedOk as Boolean = true;
    private var _lastFeedTooMuchData as Boolean = false;
    // Formatted once per fetch result, not per frame - "No Signal" can show for a long stretch while the feed is down.
    private var _noSignalCodeText as String = "";
    // Reset on pan/zoom, so "Fetching" shows for a genuine new-view load, not a same-view background poll.
    private var _viewHasFreshData as Boolean = false;
    private var _feedInFlight as Boolean = false;
    // Asked to fetch again while one was already in flight - retried once it resolves.
    private var _feedRefetchPending as Boolean = false;
    private var _feedStartMs as Number?;
    private const DETAIL_TICK_MS = 500;
    private var _lastDrawnPositions as Array<[String, Number, Number]> = [];
    // [hex, x0, y0, x1, y1] - hex-tagged so a label may overlap its own icon/chevron/reticle, only another's clips.
    private var _reservedRects as
        Array<[String, Number, Number, Number, Number]> = [];
    // The compact detail panel's built segments, dropped per fetch result - see _buildDetailLinesCached.
    private var _detailLinesCache as Array<Array<DrawUtils.ValueRun> >?;
    private var _detailLinesCacheHex as String?;
    // [singleColorMode, useMetricUnits, trackLoading, trackLoaded] - all affect the built output but aren't tied to any poll.
    private var _detailLinesCacheFlags as [Boolean, Boolean, Boolean, Boolean]?;
    // Same idea, for every visible aircraft's on-map label - see _buildLabelLinesCached.
    // [top, bottom, topMeasure, bottomMeasure] - measures are null for an empty line.
    typedef LabelEntry as
        [
            Array<DrawUtils.ValueRun>,
            Array<DrawUtils.ValueRun>,
            [Number, Array<Number>]?,
            [Number, Array<Number>]?,
        ];
    private var _labelLinesCache as Dictionary<String, LabelEntry> = {};
    // [showCallsign, showSpeed, showAltitude, singleColorMode, useMetricUnits].
    private var _labelLinesCacheFlags as
        [Boolean, Boolean, Boolean, Boolean, Boolean]?;

    private var _selection as Selection = new Selection();
    private var _manualFocus as [Float, Float]?;
    private var _dragStartCoords as [Number, Number]?;
    private var _dragLastCoords as [Number, Number]?;
    private var _dragCommitted as Boolean = false;
    private var _touchDownInDetailPanel as Boolean = false;
    private var _lastRadiusPx as Number = 1;
    private var _lastScreenHeight as Number = 1;
    // Half-width of the compact panel's widest line, cached from the last draw for tap hit-testing.
    private var _lastDetailPanelHalfWidthPx as Number = 0;
    // Timestamp-gated, not a plain flag - a standalone tap may never fire beginDrag on real hardware.
    private var _dragStopAtMs as Number?;
    private const TAP_SUPPRESS_WINDOW_MS = 300;
    // Trailing touch events from opening/closing the full-detail view can bleed into whatever's on top next.
    private var _inputSuppressedUntilMs as Number?;

    private var _tickTimer as Timer.Timer?;
    private var _ticksSincePoll as Number = 0;
    // Held here, not a local - an unreferenced Timer can be garbage-collected before it fires.
    private var _detailTimer as Timer.Timer?;
    private const TICK_MS = 250;
    // Doubled in battery saver mode, set once per timer start - a running Timer's interval can't change.
    private var _tickIntervalMs as Number = TICK_MS;
    // The screen going dark (wrist down) doesn't hide this view, so the tick is stopped here instead of in onHide.
    private var _displayOff as Boolean = false;
    private var _tickPausedForDisplay as Boolean = false;
    private var _detailTickPausedForDisplay as Boolean = false;

    private var _zoomChangedAtMs as Number?;
    // Not lower - _onTick's own cadence (TICK_MS) is the real floor on how fast this can fire.
    private const ZOOM_DEBOUNCE_MS = TICK_MS;
    private var _feedRetryAtMs as Number?;
    private var _feedRetryBackoffMs as Number = FEED_INITIAL_RETRY_BACKOFF_MS;
    private const FEED_INITIAL_RETRY_BACKOFF_MS = 1000;
    private const FEED_MAX_RETRY_BACKOFF_MS = 16000;

    private var _noGpsText as String = "";
    private var _noSignalText as String = "";
    private var _tooBusyText as String = "";
    private var _fetchingText as String = "";
    private var _liveText as String = "";
    private var _fontSmall as Graphics.FontType = Graphics.FONT_SMALL;
    private var _fontTiny as Graphics.FontType = Graphics.FONT_XTINY;

    private var _feedClient as AdsbFiClient = new AdsbFiClient();
    private var _map as BackgroundMap = new BackgroundMap();
    private var _airports as NearbyAirports = new NearbyAirports();
    private var _icons as AircraftIcons = new AircraftIcons();
    private var _fetcher as SelectionFetcher;

    public function initialize() {
        View.initialize();
        _fetcher = new SelectionFetcher(_selection, _map.client);
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
        var charSize = DrawUtils.measureChar(dc, _fontTiny);
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
        _map.onLayout(_edgeMargin, _fontTiny);
        _airports.onLayout(_fontTiny);
    }

    public function onShow() as Void {
        _startTick();

        if (!_hasFix) {
            _tryLastKnownPosition();
        }
        _fetchFeed();
    }

    // A cold GPS fix can take 30s+, longer than the screen stays on - seed from the cached last-known fix meanwhile.
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
                _userLat = lat;
                _userLon = lon;
                _hasFix = true;
                return;
            }
        }

        // currentLocation goes stale/null about an hour after anything last used GPS - fall back to this app's persisted real fix.
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
            _userLat = storedLat as Float;
            _userLon = storedLon as Float;
            _hasFix = true;
        }
    }

    public function onHide() as Void {
        _stopTick();
        _tickPausedForDisplay = false;
    }

    // A single recurring Timer, not two - a second one alongside the poll timer hit the "Too Many Timers" limit.
    private function _startTick() as Void {
        _tickIntervalMs = Settings.batterySaverMode ? TICK_MS * 2 : TICK_MS;
        var timer = new Timer.Timer();
        timer.start(method(:_onTick), _tickIntervalMs, true);
        _tickTimer = timer;
        _ticksSincePoll = 0;
    }

    private function _stopTick() as Void {
        if (_tickTimer != null) {
            (_tickTimer as Timer.Timer).stop();
            _tickTimer = null;
        }
    }

    // Called on real app exit, not onHide - onHide also fires for every menu/detail view pushed on top.
    public function persistLastKnownPosition() as Void {
        var fix = _liveFix;
        if (fix != null) {
            Storage.setValue(STORAGE_KEY_LAT, fix[0]);
            Storage.setValue(STORAGE_KEY_LON, fix[1]);
            Storage.setValue(STORAGE_KEY_TS, fix[2]);
        }
    }

    public function onDisplayModeChanged(mode as System.DisplayMode) as Void {
        var wasOff = _displayOff;
        _displayOff = mode == System.DISPLAY_MODE_OFF;
        if (!wasOff && _displayOff) {
            if (_tickTimer != null) {
                _stopTick();
                _tickPausedForDisplay = true;
            }
            if (_detailTimer != null) {
                _stopDetailTimer();
                _detailTickPausedForDisplay = true;
            }
        } else if (wasOff && !_displayOff) {
            if (_tickPausedForDisplay) {
                _tickPausedForDisplay = false;
                _startTick();
                _fetchFeed();
            }
            if (_detailTickPausedForDisplay) {
                _detailTickPausedForDisplay = false;
                _startDetailTimer();
            }
        }
    }

    public function _onTick() as Void {
        var now = System.getTimer();

        // Timer context only - a precaution against dispatching inside a Communications callback.
        _map.client.tick();

        // A fetch deferred by a busy MapTileClient has no other wake-up, but a failure's backoff still wins.
        if (_feedRefetchPending && _feedRetryAtMs == null) {
            _fetchFeed();
        }
        _fetcher.retryDeferred();

        // A hung callback would otherwise stall forever.
        if (_feedInFlight and FetchTimeout.expired(_feedStartMs, now)) {
            _onFeedResult([], false, false, 0);
        }
        _fetcher.checkTimeouts(now);

        // Debounced: a burst of zoom taps only fetches once, shortly after the last one.
        var changedAt = _zoomChangedAtMs;
        if (
            changedAt != null &&
            now - (changedAt as Number) >= ZOOM_DEBOUNCE_MS
        ) {
            _zoomChangedAtMs = null;
            _fetchFeed();
        }

        _map.expireStaleTiles(now);

        var nextRetry = _feedRetryAtMs;
        if (nextRetry != null) {
            // A failure retries on its own backoff, not the poll cadence - quick recovery without re-triggering a rate limit.
            if (now >= (nextRetry as Number)) {
                _feedRetryAtMs = null;
                _fetchFeed();
            }
        } else if (!_feedInFlight) {
            // Not counted while in flight - otherwise a round trip longer than pollMs queues the next poll back-to-back.
            _ticksSincePoll += 1;
            var pollMs = Settings.zoomPollMs();
            if (Settings.batterySaverMode) {
                pollMs *= BATTERY_SAVER_MULTIPLIER;
            }
            if (_ticksSincePoll * _tickIntervalMs >= pollMs) {
                _ticksSincePoll = 0;
                _fetchFeed();
            }
        }

        // Also run here, since nothing else rechecks the debounce; _lastScreenHeight > 1 skips the pre-first-draw default.
        if (
            Settings.showBackgroundMap &&
            _hasFix &&
            _userLat != null &&
            _userLon != null &&
            _lastScreenHeight > 1 &&
            !isDragActive()
        ) {
            var focus = _focusPoint();
            var screenSize = _lastScreenHeight;
            if (
                _map.maybeFetch(
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
        _userLat = deg[0].toFloat();
        _userLon = deg[1].toFloat();
        _liveFix = [_userLat as Float, _userLon as Float, Time.now().value()];

        var firstFix = !_hasFix;
        _hasFix = true;
        if (firstFix) {
            _fetchFeed();
        }

        WatchUi.requestUpdate();
    }

    public function zoomIn() as Void {
        if (Settings.zoomIn()) {
            _scheduleDebouncedFetch();
            WatchUi.requestUpdate();
        }
    }

    public function zoomOut() as Void {
        if (Settings.zoomOut()) {
            _scheduleDebouncedFetch();
            WatchUi.requestUpdate();
        }
    }

    // A fresh zoom action supersedes any pending failure retry for the old level.
    private function _scheduleDebouncedFetch() as Void {
        _zoomChangedAtMs = System.getTimer();
        _feedRetryAtMs = null;
        _feedRetryBackoffMs = FEED_INITIAL_RETRY_BACKOFF_MS;
        _viewHasFreshData = false;
    }

    // False when nothing's left to clear - lets the caller fall through to exit.
    public function recenter() as Boolean {
        if (_manualFocus != null) {
            _manualFocus = null;
            _viewHasFreshData = false;
            _fetchFeed();
            WatchUi.requestUpdate();
            return true;
        }
        if (_selection.hex != null) {
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
            _userLat == null or
            _userLon == null
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
                $.DRAG_THRESHOLD_PX * $.DRAG_THRESHOLD_PX
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
            _fetchFeed();
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
        // _lastDrawnPositions can outlive a lost fix - onUpdate stops drawing them, but a tap could still hit the stale spots.
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
        if (_selection.isSelected(hex)) {
            return;
        }
        _selection.select(hex, _aircraftByHex[hex]);
        _manualFocus = null;
        _fetcher.onSelect();
        _map.requestRefetch();
        WatchUi.requestUpdate();
    }

    public function deselectAircraft() as Void {
        _selection.clear();
        _map.requestRefetch();
        WatchUi.requestUpdate();
    }

    // Freezes the camera at its current position first, so tapping empty space doesn't also recenter to self.
    public function deselectAircraftKeepView() as Void {
        if (_selection.hex != null) {
            _manualFocus = _focusPoint();
        }
        deselectAircraft();
    }

    private function _isInDetailPanelZone(x as Number, y as Number) as Boolean {
        var ac = _selection.aircraft;
        if (ac == null) {
            return false;
        }
        var panelH = _detailPanelHeight(ac as Aircraft);
        return (
            panelH != 0 &&
            y >= _lastScreenHeight - panelH - CHEVRON_TAP_MARGIN_PX &&
            (x - _lastScreenHeight / 2).abs() <=
                _lastDetailPanelHalfWidthPx + DETAIL_TAP_SIDE_MARGIN_PX
        );
    }

    // True (and opens full detail) for a tap on the compact panel's actual text/chevron, not the full-width band.
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
        var ac = _selection.aircraft;
        if (ac == null) {
            return;
        }
        var header =
            (ac as Aircraft).flight != null &&
            ((ac as Aircraft).flight as String).length() > 0
                ? (ac as Aircraft).flight as String
                : (ac as Aircraft).hex;
        var built = DetailRows.full(ac as Aircraft);
        // Reuses the radar's own ring/panel geometry so the separators line up with the radar underneath.
        var ringCx = _lastScreenHeight / 2;
        // Bottom band matches the header's height, not the variable compact panel's.
        var bandH = _topPanelHeight();
        var view = new AircraftDetailView(
            header,
            _icons.colorFor(ac as Aircraft),
            built[0],
            built[1],
            built[2],
            built[3],
            ringCx,
            ringCx,
            _lastRadiusPx,
            bandH,
            bandH,
            _edgeMargin,
            method(:onDetailClosed)
        );
        WatchUi.pushView(
            view,
            new AircraftDetailDelegate(view),
            WatchUi.SLIDE_UP
        );
        _fetcher.onDetailOpened(view);
        _startDetailTimer();
    }

    // pushView's onHide stops _onTick, so retries and timeouts need their own tick while the detail view is up.
    private function _startDetailTimer() as Void {
        _stopDetailTimer();
        var timer = new Timer.Timer();
        timer.start(method(:_onDetailTick), DETAIL_TICK_MS, true);
        _detailTimer = timer;
    }

    public function _onDetailTick() as Void {
        _map.client.tick();
        _fetcher.retryDeferredRoute();
        _fetcher.checkRouteTimeouts(System.getTimer());
    }

    private function _stopDetailTimer() as Void {
        if (_detailTimer != null) {
            (_detailTimer as Timer.Timer).stop();
            _detailTimer = null;
        }
    }

    public function onDetailClosed() as Void {
        _fetcher.onDetailClosed();
        _stopDetailTimer();
        _detailTickPausedForDisplay = false;
        suppressInputBriefly();
    }

    private function _fetchFeed() as Void {
        if (_feedInFlight) {
            _feedRefetchPending = true;
            return;
        }
        if (!_hasFix or _userLat == null or _userLon == null) {
            _map.client.resumeFor(:poll);
            return;
        }
        if (_map.client.pauseAndCheckBusy(:poll)) {
            _feedRefetchPending = true;
            return;
        }
        _feedRefetchPending = false;
        var focus = _focusPoint();
        _feedInFlight = true;
        _feedStartMs = System.getTimer();
        _feedClient.fetch(
            focus[0],
            focus[1],
            Settings.zoomRadiusKm(),
            method(:_onFeedResult)
        );
    }

    public function _onFeedResult(
        aircraft as Array<Aircraft>,
        ok as Boolean,
        tooMuchData as Boolean,
        code as Number
    ) as Void {
        _feedInFlight = false;
        _lastFeedOk = ok;
        _lastFeedTooMuchData = tooMuchData;
        if (!ok) {
            _noSignalCodeText = _noSignalText + " " + code.toString();
        }
        ApiStatus.setFeed(ok, code);
        _map.client.resumeFor(:poll);

        if (ok) {
            _ticksSincePoll = 0;
            _feedRetryAtMs = null;
            _feedRetryBackoffMs = FEED_INITIAL_RETRY_BACKOFF_MS;
            _viewHasFreshData = true;

            var byHex = ({}) as Dictionary<String, Aircraft>;
            for (var i = 0; i < aircraft.size(); i++) {
                byHex[aircraft[i].hex] = aircraft[i];
            }
            _aircraft = aircraft;
            _aircraftByHex = byHex;
            _icons.clearClassifyCache();
            _detailLinesCacheHex = null;
            _labelLinesCache = {};

            if (_selection.refresh(byHex)) {
                // _focusPoint() would fall through to the user's position here - freeze the last fix instead.
                if (_manualFocus == null) {
                    _manualFocus = _selection.lastPos;
                }
                deselectAircraft();
            }
        } else {
            _feedRetryAtMs = System.getTimer() + _feedRetryBackoffMs;
            _feedRetryBackoffMs *= 2;
            if (_feedRetryBackoffMs > FEED_MAX_RETRY_BACKOFF_MS) {
                _feedRetryBackoffMs = FEED_MAX_RETRY_BACKOFF_MS;
            }
        }

        // Not retried synchronously - a queued tile needs a tick between resumeFor() and the next pause to dispatch.
        if (_feedRefetchPending) {
            _ticksSincePoll = 0;
        }

        WatchUi.requestUpdate();
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

        if (!_hasFix or _userLat == null or _userLon == null) {
            dc.setColor(Palette.WHITE, Graphics.COLOR_TRANSPARENT);
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

        var selected = _selection.aircraft;
        var detailLines =
            selected != null
                ? _buildDetailLinesCached(selected as Aircraft)
                : [] as Array<Array<DrawUtils.ValueRun> >;
        var bottomPanelH = _detailPanelHeightFor(detailLines);

        if (Settings.showBackgroundMap) {
            _map.syncStyle();
            // Fetches never fire mid-drag anyway, so skip the trig work every drag frame.
            if (!isDragActive()) {
                _map.maybeFetch(
                    focusLat,
                    focusLon,
                    radiusPx,
                    radiusKm,
                    cx,
                    cy,
                    w,
                    h
                );
            }
            _map.draw(dc, cx, cy, radiusPx, radiusKm, focusLat, focusLon);
        } else {
            _map.release();
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
        if (Settings.showAirports) {
            _airports.maybeFetch(focusLat, focusLon, radiusKm);
            _airports.draw(dc, focusLat, focusLon, cx, cy, radiusPx, radiusKm);
        }
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
        if (_selection.hex != null) {
            var selected = _selection.aircraft;
            if (selected != null) {
                return [(selected as Aircraft).lat, (selected as Aircraft).lon];
            }
            // A missed poll (tolerated up to Selection's MAX_MISSES) holds the last position instead of recentering on the user.
            var lastPos = _selection.lastPos;
            if (lastPos != null) {
                return lastPos as [Float, Float];
            }
        }
        return [_userLat as Float, _userLon as Float];
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
                    var ringPx = NumUtils.round((ringKm * radiusPx) / radiusKm);
                    dc.setStroke(
                        DrawUtils.withAlpha(Palette.RING, Palette.RING_ALPHA)
                    );
                    dc.drawCircle(cx, cy, ringPx);
                    _drawRingLabel(
                        dc,
                        cx,
                        cy,
                        ringPx,
                        ringKm,
                        topPanelH,
                        Palette.GRID_LABEL
                    );
                    ringKm += stepKm;
                }
            }
        }
        // Boundary ring drawn more solid, like a scope's detection edge - always shown, marks the zoom radius itself.
        dc.setStroke(DrawUtils.withAlpha(Palette.RING, Palette.BOUNDARY_ALPHA));
        dc.drawCircle(cx, cy, radiusPx);
        // White, not the usual dim grid-label grey - this is the actual current zoom level, not a secondary reference ring.
        _drawRingLabel(
            dc,
            cx,
            cy,
            radiusPx,
            radiusKm,
            topPanelH,
            Palette.WHITE
        );

        if (Settings.showRangeRings) {
            for (var deg = 0; deg < 360; deg += 30) {
                var cardinal = deg % 90 == 0;
                dc.setStroke(
                    DrawUtils.withAlpha(
                        Palette.RING,
                        cardinal ? Palette.TICK_ALPHA : Palette.MINOR_TICK_ALPHA
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
        var x = cx + NumUtils.round(ringPx * Math.sin(theta));
        var y = cy - NumUtils.round(ringPx * Math.cos(theta));
        if (y < topPanelH + 10) {
            return;
        }
        _drawGridLabel(dc, x, y, Formatters.km(ringKm), color);
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
        return pow10 * (d >= 5.0 ? 5.0 : d >= 3.0 ? 3.0 : d >= 2.0 ? 2.0 : 1.0);
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
            cx + NumUtils.round(radiusPx * sinT),
            cy - NumUtils.round(radiusPx * cosT),
            cx + NumUtils.round((radiusPx - tickLen) * sinT),
            cy - NumUtils.round((radiusPx - tickLen) * cosT)
        );
    }

    // Angles are eyeballed compass bearings from the real device (0deg=up/north, clockwise).
    private function _drawButtonHints(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number
    ) as Void {
        var ringR =
            (radiusPx +
                (dc.getWidth() < dc.getHeight()
                    ? dc.getWidth()
                    : dc.getHeight()) /
                    2) /
            2;

        var plusPos = _buttonHintPos(cx, cy, ringR, 270.0);
        var minusPos = _buttonHintPos(cx, cy, ringR, 240.0);
        var menuPos = _buttonHintPos(cx, cy, ringR, 60.0);
        var recenterPos = _buttonHintPos(cx, cy, ringR, 120.0);

        _drawPlusHint(dc, plusPos[0], plusPos[1]);
        _drawMinusHint(dc, minusPos[0], minusPos[1]);
        _drawMenuHint(dc, menuPos[0], menuPos[1]);
        _drawRecenterHint(dc, recenterPos[0], recenterPos[1]);
    }

    // Conservative any-angle bound on a hint's reach - the real radial reach at each hint's angle is at most 6px.
    private const BUTTON_HINT_REACH_PX = 9;

    private function _buttonHintPos(
        cx as Number,
        cy as Number,
        ringR as Number,
        compassDeg as Float
    ) as [Number, Number] {
        var theta = Math.toRadians(compassDeg);
        var x = cx + NumUtils.round(ringR * Math.sin(theta));
        var y = cy - NumUtils.round(ringR * Math.cos(theta));
        return [x, y];
    }

    // Zoom in (KEY_UP). White, not Palette.TEXT, to match the chevron's brightness.
    private function _drawPlusHint(dc as Dc, x as Number, y as Number) as Void {
        dc.setColor(Palette.WHITE, Graphics.COLOR_TRANSPARENT);
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
        dc.setColor(Palette.WHITE, Graphics.COLOR_TRANSPARENT);
        var s = 6;
        dc.drawLine(x - s, y, x + s, y);
    }

    // Menu (KEY_ENTER/KEY_MENU).
    private function _drawMenuHint(dc as Dc, x as Number, y as Number) as Void {
        dc.setColor(Palette.WHITE, Graphics.COLOR_TRANSPARENT);
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
        dc.setColor(Palette.WHITE, Graphics.COLOR_TRANSPARENT);
        var s = 6;
        var gap = 2;
        dc.drawLine(x, y - s, x, y - gap);
        dc.drawLine(x, y + gap, x, y + s);
        dc.drawLine(x - s, y, x - gap, y);
        dc.drawLine(x + gap, y, x + s, y);
    }

    private function _topPanelLines() as Array<[String, Number]> {
        var lines = [] as Array<[String, Number]>;
        lines.add(_fetchStatusLine());
        if (_userLat != null && _userLon != null) {
            lines.add([
                Formatters.lat(_userLat as Float, true) +
                    " " +
                    Formatters.lon(_userLon as Float, true),
                Palette.TEXT,
            ]);
        }
        return lines;
    }

    private function _fetchStatusLine() as [String, Number] {
        if (!_lastFeedOk) {
            return _lastFeedTooMuchData
                ? [_tooBusyText, Palette.WARN]
                : [_noSignalCodeText, Palette.EMERGENCY];
        }
        if (_feedInFlight && !_viewHasFreshData) {
            return [_fetchingText, Palette.GRID_LABEL];
        }
        return [_liveText, Palette.SUCCESS];
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

        _drawPanelBorder(dc, panelH, cx, cy, radiusPx);
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
        var halfW = DrawUtils.chordHalfExtent(radiusPx, dy);
        // Palette.BOUNDARY_ALPHA, not Palette.RING_ALPHA - reads as a continuation of the boundary ring, not a secondary ring.
        dc.setStroke(DrawUtils.withAlpha(Palette.RING, Palette.BOUNDARY_ALPHA));
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
        var stepKm = Settings.zoomGridStepKm();
        var latStep = Projection.kmToDegLat(stepKm);
        var lonStep = Projection.kmToDegLon(stepKm, focusLat);
        var steps = Math.ceil(radiusKm / stepKm).toNumber();

        var latBase = Math.floor(focusLat / latStep) * latStep;
        for (var i = -steps; i <= steps; i++) {
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
            var halfW = DrawUtils.chordHalfExtent(radiusPx, dy);
            dc.setStroke(DrawUtils.withAlpha(Palette.GRID, Palette.GRID_ALPHA));
            dc.drawLine(cx - halfW, pt[1], cx + halfW, pt[1]);
            if (pt[1] > topPanelH && pt[1] < bottomLimitY) {
                _drawGridLabel(
                    dc,
                    cx - halfW + _gridLabelInset,
                    pt[1],
                    Formatters.lat(lat, false),
                    Palette.GRID_LABEL
                );
            }
        }

        var lonBase = Math.floor(focusLon / lonStep) * lonStep;
        for (var i = -steps; i <= steps; i++) {
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
            var halfH = DrawUtils.chordHalfExtent(radiusPx, dx);
            var lineTop = cy - halfH;
            var lineBottom = cy + halfH;
            dc.setStroke(DrawUtils.withAlpha(Palette.GRID, Palette.GRID_ALPHA));
            dc.drawLine(pt[0], lineTop, pt[0], lineBottom);
            var labelY = lineTop > topPanelH ? lineTop : topPanelH + 10;
            if (labelY < lineBottom) {
                _drawGridLabel(
                    dc,
                    pt[0],
                    labelY,
                    Formatters.lon(lon, false),
                    Palette.GRID_LABEL
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
        var lat = _userLat as Float;
        var lon = _userLon as Float;
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

        dc.setColor(Palette.USER, Graphics.COLOR_TRANSPARENT);
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

        dc.setColor(Palette.USER, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(pts);
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

    private function _overlapsReserved(
        hex as String,
        rect as [Number, Number, Number, Number]
    ) as Boolean {
        for (var i = 0; i < _reservedRects.size(); i++) {
            var entry = _reservedRects[i];
            if (
                rect[0] < entry[3] &&
                rect[2] > entry[1] &&
                rect[1] < entry[4] &&
                rect[3] > entry[2] &&
                !(entry[0] as String).equals(hex)
            ) {
                return true;
            }
        }
        return false;
    }

    // Auto-hides on top of the user's own Settings while "too busy" - reverts once a normal response returns.
    private function _effectiveShowGroundVehicles() as Boolean {
        return Settings.showGroundVehicles && !_lastFeedTooMuchData;
    }

    private function _effectiveHideGroundedPlanes() as Boolean {
        return Settings.hideGroundedPlanes || _lastFeedTooMuchData;
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
        var showGroundVehicles = _effectiveShowGroundVehicles();
        var hideGroundedPlanes = _effectiveHideGroundedPlanes();

        var selected = _selection.aircraft;
        if (
            selected != null &&
            Settings.showSelectedTrail &&
            Projection.distanceKm(
                focusLat,
                focusLon,
                (selected as Aircraft).lat,
                (selected as Aircraft).lon
            ) <= radiusKm
        ) {
            _drawSelectedTrail(
                dc,
                focusLat,
                focusLon,
                cx,
                cy,
                radiusPx,
                radiusKm,
                _icons.colorFor(selected as Aircraft)
            );
        }

        var selectedIndex = -1;
        for (var i = 0; i < _aircraft.size(); i++) {
            var ac = _aircraft[i];
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
            if (!DrawUtils.insideCircle(pos, cx, cy, radiusPx)) {
                continue;
            }

            var isSelected = _selection.isSelected(ac.hex);

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

            if (isSelected) {
                selectedIndex = _lastDrawnPositions.size();
            }
            _lastDrawnPositions.add([ac.hex, pos[0], pos[1]]);

            var chevronCenter = Settings.showVertRateChevron
                ? _icons.chevronCenter(pos[0], pos[1], ac)
                : null;
            // The selected aircraft only reserves space here - it's drawn once, on top, after the label pass.
            if (!isSelected) {
                _icons.drawIcon(dc, pos[0], pos[1], ac);
                if (chevronCenter != null) {
                    _icons.drawVertRateChevron(
                        dc,
                        chevronCenter as [Number, Number],
                        ac
                    );
                }
                if (ac.isEmergency()) {
                    _icons.drawEmergencyBadge(dc, pos[0], pos[1], ac);
                }
            }

            // Reserved for every aircraft ahead of the label pass, so no label covers an icon or clips a chevron.
            _reserveRect(ac.hex, _icons.iconRect(pos[0], pos[1], ac));
            if (chevronCenter != null) {
                _reserveRect(
                    ac.hex,
                    _icons.chevronRect(chevronCenter as [Number, Number])
                );
            }
            if (ac.isEmergency()) {
                _reserveRect(
                    ac.hex,
                    _icons.emergencyBadgeRect(pos[0], pos[1], ac)
                );
            }

            if (isSelected) {
                _reserveRect(
                    ac.hex,
                    _icons.selectionReticleRect(pos[0], pos[1], ac)
                );
            }
        }

        // A separate pass, after every icon - otherwise a later label could paint over an earlier icon.
        if (Settings.labelsEnabled) {
            var showCallsign = Settings.isLabelFieldEnabled("callsign");
            var showSpeed = Settings.isLabelFieldEnabled("speed");
            var showAltitude = Settings.isLabelFieldEnabled("altitude");
            var lineH = dc.getTextDimensions("Ag", _fontTiny)[1];
            _syncLabelCacheSettings(showCallsign, showSpeed, showAltitude);
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
        }

        // Re-drawn last so the selected icon/reticle/chevron sit above every other aircraft and label.
        if (selectedIndex >= 0) {
            var topEntry = _lastDrawnPositions[selectedIndex];
            _drawSelectedIconOnTop(
                dc,
                topEntry[1] as Number,
                topEntry[2] as Number,
                selected as Aircraft
            );
        }
    }

    // Bigger-class aircraft's label wins any overlap - insertion sort is cheap at on-screen counts.
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
        return ac != null ? _icons.sizeScale(ac as Aircraft) : 0.0;
    }

    private function _drawSelectedIconOnTop(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        _icons.drawIcon(dc, x, y, ac);
        if (Settings.showVertRateChevron) {
            var chevronCenter = _icons.chevronCenter(x, y, ac);
            if (chevronCenter != null) {
                _icons.drawVertRateChevron(
                    dc,
                    chevronCenter as [Number, Number],
                    ac
                );
            }
        }
        if (ac.isEmergency()) {
            _icons.drawEmergencyBadge(dc, x, y, ac);
        }
        _icons.drawSelectionReticle(dc, x, y, ac);
    }

    private const TRAIL_DASH_PX = 5.0;
    private const TRAIL_GAP_PX = 4.0;

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
        if (_selection.track.size() < 2) {
            return;
        }

        var prevScreen = null as Array<Number>?;
        var prevPt = null as [Float, Float, Number, Boolean]?;
        // Carried across dashed segments so closely spaced taxi points still alternate instead of each drawing as one dash.
        var dashPhase = 0.0;
        for (var i = 0; i < _selection.track.size(); i++) {
            var pt = _selection.track[i];
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
                        DrawUtils.withAlpha(
                            trailColor,
                            Palette.TRAIL_GROUND_ALPHA
                        )
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
                        DrawUtils.withAlpha(trailColor, Palette.TRAIL_ALPHA)
                    );
                    dc.drawLine(p0[0], p0[1], screen[0], screen[1]);
                    dashPhase = 0.0;
                }
            }
            prevScreen = screen;
            prevPt = pt;
        }
    }

    // phase is how far into the dash/gap cycle this segment starts; the return is the phase to carry into the next.
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
        // Only the on-screen part is dashed, which bounds the loop without truncating a long segment.
        var visible = _clipToScreen(x0, y0, dx, dy, dc);
        if (visible == null) {
            return endGlobal - Math.floor(endGlobal / step) * step;
        }
        var visStart = phase + visible[0] * length;
        var visEnd = phase + visible[1] * length;
        var k = Math.floor(visStart / step).toNumber();
        while (k * step <= visEnd) {
            var dashGlobalStart = k * step;
            var dashGlobalEnd = dashGlobalStart + TRAIL_DASH_PX;
            var clampedStart =
                dashGlobalStart > visStart ? dashGlobalStart : visStart;
            var clampedEnd = dashGlobalEnd < visEnd ? dashGlobalEnd : visEnd;
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

    // Liang-Barsky: the [t0, t1] slice of (x0,y0)+t*(dx,dy), t in [0,1], that lies on screen, or null if none does.
    private function _clipToScreen(
        x0 as Number,
        y0 as Number,
        dx as Float,
        dy as Float,
        dc as Dc
    ) as [Float, Float]? {
        var p = [-dx, dx, -dy, dy];
        var q = [
            x0.toFloat(),
            (dc.getWidth() - x0).toFloat(),
            y0.toFloat(),
            (dc.getHeight() - y0).toFloat(),
        ];
        var t0 = 0.0;
        var t1 = 1.0;
        for (var i = 0; i < 4; i++) {
            if (p[i] == 0.0) {
                if (q[i] < 0.0) {
                    return null;
                }
                continue;
            }
            var t = q[i] / p[i];
            if (p[i] < 0.0) {
                if (t > t1) {
                    return null;
                }
                if (t > t0) {
                    t0 = t;
                }
            } else {
                if (t < t0) {
                    return null;
                }
                if (t < t1) {
                    t1 = t;
                }
            }
        }
        return [t0, t1];
    }

    private var _labelOverlapMarginPx as Number = 4;
    private var _labelLineGapPx as Number = 2;
    // Scaled by aircraft size like the icon, with margin to clear the icon and a descent chevron at every size tier.
    private var _labelVoffsetBase as Float = 18.0;

    // Two rows (callsign / speed+altitude), not one wide line - a narrower footprint loses fewer overlap checks.
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
        var entry = _buildLabelLinesCached(
            dc,
            ac,
            showCallsign,
            showSpeed,
            showAltitude
        );
        var top = entry[0];
        var bottom = entry[1];
        if (top.size() == 0 && bottom.size() == 0) {
            return;
        }

        var topM = entry[2];
        var bottomM = entry[3];
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

        var textY = y + (_labelVoffsetBase * _icons.sizeScale(ac)).toNumber();
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
        segments as Array<DrawUtils.ValueRun>
    ) as [Number, Array<Number>] {
        var widths = [] as Array<Number>;
        var totalW = -_segmentGapPx;
        for (var i = 0; i < segments.size(); i++) {
            var w = DrawUtils.runWidth(dc, _fontTiny, segments[i]);
            widths.add(w);
            totalW += w + _segmentGapPx;
        }
        return [totalW, widths] as [Number, Array<Number>];
    }

    private function _drawMeasuredSegments(
        dc as Dc,
        cx as Number,
        y as Number,
        segments as Array<DrawUtils.ValueRun>,
        widths as Array<Number>,
        totalW as Number
    ) as Void {
        var x = cx - Math.round(totalW / 2.0).toNumber();
        for (var i = 0; i < segments.size(); i++) {
            DrawUtils.drawRun(dc, x, y, _fontTiny, segments[i]);
            x += (widths[i] as Number) + _segmentGapPx;
        }
    }

    // Once per frame, not per aircraft - drops every cached label when a setting that shapes them changed.
    private function _syncLabelCacheSettings(
        showCallsign as Boolean,
        showSpeed as Boolean,
        showAltitude as Boolean
    ) as Void {
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
    }

    // Measured when built, not per redraw - this runs for every labeled aircraft, every frame.
    private function _buildLabelLinesCached(
        dc as Dc,
        ac as Aircraft,
        showCallsign as Boolean,
        showSpeed as Boolean,
        showAltitude as Boolean
    ) as LabelEntry {
        var cached = _labelLinesCache[ac.hex];
        if (cached != null) {
            return cached;
        }
        var lines = _buildLabelLines(ac, showCallsign, showSpeed, showAltitude);
        var top = lines[0];
        var bottom = lines[1];
        var entry =
            [
                top,
                bottom,
                top.size() > 0 ? _measureSegments(dc, top) : null,
                bottom.size() > 0 ? _measureSegments(dc, bottom) : null,
            ] as LabelEntry;
        _labelLinesCache[ac.hex] = entry;
        return entry;
    }

    // Same colors as the detail views (callsign=aircraft, speed=yellow, altitude=blue), so labels read consistently.
    private function _buildLabelLines(
        ac as Aircraft,
        showCallsign as Boolean,
        showSpeed as Boolean,
        showAltitude as Boolean
    ) as [Array<DrawUtils.ValueRun>, Array<DrawUtils.ValueRun>] {
        var top = [] as Array<DrawUtils.ValueRun>;
        if (showCallsign) {
            var cs = ac.flight;
            if (cs != null && cs.length() > 0) {
                top.add(DrawUtils.plainRun(cs as String, _icons.colorFor(ac)));
            }
        }

        var bottom = [] as Array<DrawUtils.ValueRun>;
        if (showSpeed && ac.gs != null) {
            bottom.add(
                DrawUtils.plainRun(
                    Formatters.speedKt(NumUtils.round(ac.gs as Float)),
                    Palette.SPEED
                )
            );
        }
        if (showAltitude) {
            if (ac.onGround) {
                bottom.add(DrawUtils.plainRun("GND", Palette.ALT));
            } else if (ac.altBaro != null) {
                bottom.add(
                    DrawUtils.plainRun(
                        Formatters.altitude(ac.altBaro as Number),
                        Palette.ALT
                    )
                );
            }
        }

        return (
            [top, bottom] as
            [Array<DrawUtils.ValueRun>, Array<DrawUtils.ValueRun>]
        );
    }

    private function _drawDetailPanel(
        dc as Dc,
        cx as Number,
        cy as Number,
        h as Number,
        radiusPx as Number,
        lines as Array<Array<DrawUtils.ValueRun> >
    ) as Void {
        if (lines.size() == 0) {
            return;
        }

        var panelH = _detailPanelHeightFor(lines);
        var panelY = h - panelH;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        // Stops one row short of panelY, like the top panel, so _drawPanelBorder's line isn't drawn over bare black.
        dc.fillRectangle(0, panelY + 1, dc.getWidth(), panelH - 1);

        var maxLineW = 0;
        for (var i = 0; i < lines.size(); i++) {
            var line = lines[i] as Array<DrawUtils.ValueRun>;
            var measured = _measureSegments(dc, line);
            var lineW = measured[0] as Number;
            if (lineW > maxLineW) {
                maxLineW = lineW;
            }
            _drawMeasuredSegments(
                dc,
                cx,
                panelY + 4 + i * _detailPanelLineHeight,
                line,
                measured[1] as Array<Number>,
                lineW
            );
        }
        _lastDetailPanelHalfWidthPx = maxLineW / 2;

        _drawPanelBorder(dc, panelY, cx, cy, radiusPx);
        _drawChevronUp(dc, cx, panelY - _chevronMarginPx, CHEVRON_SIZE_PX);
    }

    private function _detailPanelHeight(ac as Aircraft) as Number {
        return _detailPanelHeightFor(_buildDetailLinesCached(ac));
    }

    private function _detailPanelHeightFor(
        lines as Array<Array<DrawUtils.ValueRun> >
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
    // Extra tap area on each side of the panel's actual text width, same touch-tolerance idea as HIT_RADIUS_PX.
    private const DETAIL_TAP_SIDE_MARGIN_PX = 20;

    // Full white, not Palette.TEXT - an affordance should read brighter than the panel content.
    private function _drawChevronUp(
        dc as Dc,
        x as Number,
        y as Number,
        s as Number
    ) as Void {
        dc.setColor(Palette.WHITE, Graphics.COLOR_TRANSPARENT);
        DrawUtils.drawChevron(dc, x, y, s, true);
    }

    private var _segmentGapPx as Number = 6;

    // Rebuilds only when the selection/data actually changes, not on every redraw (e.g. every drag frame).
    private function _buildDetailLinesCached(
        ac as Aircraft
    ) as Array<Array<DrawUtils.ValueRun> > {
        var flags =
            [
                Settings.singleColorMode,
                Settings.useMetricUnits,
                _fetcher.isTrackLoading(),
                _selection.trackHasHistory,
            ] as [Boolean, Boolean, Boolean, Boolean];
        var cachedFlags = _detailLinesCacheFlags;
        if (
            cachedFlags == null or
            cachedFlags[0] != flags[0] or
            cachedFlags[1] != flags[1] or
            cachedFlags[2] != flags[2] or
            cachedFlags[3] != flags[3]
        ) {
            _detailLinesCacheHex = null;
            _detailLinesCacheFlags = flags;
        }
        var cache = _detailLinesCache;
        var cacheHex = _detailLinesCacheHex;
        if (cache != null and cacheHex != null and cacheHex.equals(ac.hex)) {
            return cache;
        }
        var lines = DetailRows.compact(
            ac,
            _icons.colorFor(ac),
            flags[2],
            flags[3]
        );
        _detailLinesCache = lines;
        _detailLinesCacheHex = ac.hex;
        return lines;
    }
}
