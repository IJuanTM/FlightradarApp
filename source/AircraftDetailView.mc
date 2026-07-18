import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

// Custom full-screen view, not a system Menu2 - black background, styled like the rest of this app. RadarView builds the row data and passes its own ring/panel geometry (see initialize()) so this view's boundary ring and top/bottom separators line up exactly with where they sit on the radar underneath.
class AircraftDetailView extends WatchUi.View {
    private var _headerText as String;
    private var _headerColor as Number;
    private var _rows as Array<Array<[String, String, Number]> >;
    private var _routeRowIndex as Number;
    private var _scrollPx as Number = 0;
    private var _fontTiny as Graphics.FontType = Graphics.FONT_XTINY;
    private var _fontSmall as Graphics.FontType = Graphics.FONT_SMALL;

    private var _ringCx as Number;
    private var _ringCy as Number;
    private var _ringRadiusPx as Number;
    private var _topY as Number;
    private var _bottomY as Number = 0;
    private var _bottomPanelH as Number;

    // Row height is computed, not fixed - a short row list stretches (up to MAX) to fill the available space instead of leaving dead space below it; a long list clamps to MIN and scrolls.
    private var _rowHeight as Number = MIN_ROW_HEIGHT;
    private var _contentTop as Number = 0;
    private var _visibleHeight as Number = 1;
    private var _closeChevronY as Number = 0;

    private const MIN_ROW_HEIGHT = 20;
    private const MAX_ROW_HEIGHT = 28;
    private const CONTENT_PADDING = 6;
    private const COLOR_ROW_LABEL = 0x999999;

    // Must match RadarView's own COLOR_RING/COLOR_BOUNDARY_ALPHA/COLORS[0] (GRAYS[4], 0x40, white) - duplicated here since this is a separate view class with no access to RadarView's private constants. Use this, not Graphics.COLOR_WHITE, for content colors - matches the app's own COLORS-array convention rather than a hand-picked system constant.
    private const COLOR_RING = 0xaaaaaa;
    private const COLOR_BOUNDARY_ALPHA = 0x40;
    private const COLOR_WHITE = 0xffffff;

    // Every row (1 or 2 fields) draws as one horizontally-centered inline line, same visual language as the compact panel's _drawSegmentedLine - no separate "hero" font, so nothing on this screen looks bigger than anything else by accident.
    private const LABEL_VALUE_GAP_PX = 4;
    private const FIELD_GAP_PX = 16;

    // Embedded in a value string by RadarView to mark where a code-drawn degree circle goes - this app's custom bitmap fonts don't have a "°" glyph baked in, same fix TerminalWatchface uses (_drawSmallTempNum/_glowCircle) for the same reason.
    private const DEGREE_MARK = "^";
    // Both sides measure the same raw pixel gap from the circle's edge to the text's advance-width edge, but it reads tighter on the right - letters (e.g. "C") apparently carry less built-in left-side bearing than digits carry right-side bearing in this font. Right gap biased larger to compensate.
    private const DEGREE_MARK_GAP_LEFT = 1;
    private const DEGREE_MARK_GAP_RIGHT = 2;
    private const DEGREE_MARK_R = 1;
    // Text y is the top of the glyph box, so a circle centered there sits high (superscript-like) - nudged down to align with the text's visual middle instead.
    private const DEGREE_MARK_Y_OFFSET = 4;

    private const CHEVRON_SIZE = 7;
    private const CHEVRON_TAP_PAD = 16;
    private const CLOSE_TEXT = "Close";
    private const CLOSE_CHEVRON_GAP = 10;

    public function initialize(
        headerText as String,
        headerColor as Number,
        rows as Array<Array<[String, String, Number]> >,
        routeRowIndex as Number,
        ringCx as Number,
        ringCy as Number,
        ringRadiusPx as Number,
        topPanelH as Number,
        bottomPanelH as Number
    ) {
        View.initialize();
        _headerText = headerText;
        _headerColor = headerColor;
        _rows = rows;
        _routeRowIndex = routeRowIndex;
        _ringCx = ringCx;
        _ringCy = ringCy;
        _ringRadiusPx = ringRadiusPx;
        _topY = topPanelH;
        _bottomPanelH = bottomPanelH;
    }

    public function onLayout(dc as Dc) as Void {
        _fontTiny =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_TINY) as
            Graphics.FontDefinition;
        _fontSmall =
            WatchUi.loadResource(Rez.Fonts.SpaceMono_SMALL) as
            Graphics.FontDefinition;

        var h = dc.getHeight();
        _bottomY = h - _bottomPanelH;

        var contentTop0 = _topY + CONTENT_PADDING;
        var available = _bottomY - CONTENT_PADDING - contentTop0;
        var count = _rows.size();
        var rowH = count > 0 ? available / count : MIN_ROW_HEIGHT;
        if (rowH < MIN_ROW_HEIGHT) {
            rowH = MIN_ROW_HEIGHT;
        } else if (rowH > MAX_ROW_HEIGHT) {
            rowH = MAX_ROW_HEIGHT;
        }
        _rowHeight = rowH;
        _visibleHeight = available;

        // Actual visual content height, not count*rowH - the trailing gap after the last row's own text isn't really "content", counting it made the block look biased toward the top of the band instead of centered.
        var lineH = dc.getTextDimensions("Ag", _fontTiny)[1];
        var used = count > 0 ? (count - 1) * rowH + lineH : 0;
        _contentTop =
            used < available
                ? contentTop0 + (available - used) / 2
                : contentTop0;
    }

    // Called from RadarView._onRouteResult once the async OpenSky route fetch resolves. Route always sits alone in its own row, so cell 0. Color is passed in (not fixed) so RadarView can dim it for the unknown/failed states, same as "No Track History" in the compact panel.
    public function setRouteText(text as String, color as Number) as Void {
        if (_routeRowIndex < 0 || _routeRowIndex >= _rows.size()) {
            return;
        }
        var row = _rows[_routeRowIndex];
        var cell = row[0];
        row[0] = [cell[0], text, color];
        WatchUi.requestUpdate();
    }

    public function scroll(dyPx as Number) as Void {
        _scrollPx += dyPx;
        var maxScroll = _rows.size() * _rowHeight - _visibleHeight;
        if (maxScroll < 0) {
            maxScroll = 0;
        }
        if (_scrollPx < 0) {
            _scrollPx = 0;
        } else if (_scrollPx > maxScroll) {
            _scrollPx = maxScroll;
        }
        WatchUi.requestUpdate();
    }

    // Tap-to-close target for the down chevron drawn at the bottom of the screen - kept generous (CHEVRON_TAP_PAD) since it's a small glyph.
    public function isCloseChevronHit(x as Number, y as Number) as Boolean {
        return (x - _ringCx).abs() <= CHEVRON_TAP_PAD &&
            (y - _closeChevronY).abs() <= CHEVRON_TAP_PAD;
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        // Same boundary ring the radar itself draws, at the exact same cx/cy/radius - covered by the black top/bottom bands below, visible only in the content band in between.
        dc.setStroke(_withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawCircle(_ringCx, _ringCy, _ringRadiusPx);

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, w, _topY);
        // Starts one row below _bottomY, not at it - leaves the boundary-ring pixel at _bottomY itself unerased, so the separator drawn there sits on top of it seamlessly instead of on bare black (mirrors the top band, which already stops one row short of _topY for the same reason).
        dc.fillRectangle(0, _bottomY + 1, w, h - _bottomY - 1);

        _drawRingSeparator(dc, _topY);
        _drawRingSeparator(dc, _bottomY);

        dc.setColor(_headerColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            _topY / 2,
            _fontSmall,
            _headerText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        for (var i = 0; i < _rows.size(); i++) {
            var y = _contentTop + i * _rowHeight - _scrollPx;
            if (y + _rowHeight < _contentTop || y > _bottomY) {
                continue;
            }
            _drawGridRow(dc, cx, y, _rows[i]);
        }

        _drawCloseAffordance(dc, cx, h);
    }

    // A horizontal line at y, width clamped to the chord of the boundary ring at that height - touches the ring on both ends instead of floating independently of it.
    private function _drawRingSeparator(dc as Dc, y as Number) as Void {
        var dy = (y - _ringCy).abs();
        if (dy >= _ringRadiusPx) {
            return;
        }
        var halfW = _chordHalfExtent(_ringRadiusPx, dy);
        // COLOR_BOUNDARY_ALPHA, not a dimmer tone - this line reads as a continuation of the boundary ring, so it needs the same opacity as the ring itself.
        dc.setStroke(_withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawLine(_ringCx - halfW, y, _ringCx + halfW, y);
    }

    private function _chordHalfExtent(
        radiusPx as Number,
        offsetPx as Number
    ) as Number {
        return Math.sqrt(
            (radiusPx * radiusPx - offsetPx * offsetPx).toFloat()
        ).toNumber();
    }

    private function _withAlpha(color as Number, alpha as Number) as Number {
        return (alpha << 24) | (color & 0xffffff);
    }

    // "Close" text plus a down chevron, the pair vertically centered in the band below _bottomY - mirrors the up chevron RadarView draws above the compact panel.
    private function _drawCloseAffordance(
        dc as Dc,
        cx as Number,
        h as Number
    ) as Void {
        var closeH = dc.getTextDimensions(CLOSE_TEXT, _fontTiny)[1];
        var blockH = closeH + CLOSE_CHEVRON_GAP + CHEVRON_SIZE;
        var bandH = h - _bottomY;
        var blockTop = _bottomY + (bandH - blockH) / 2;

        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            blockTop,
            _fontTiny,
            CLOSE_TEXT,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        _closeChevronY = blockTop + closeH + CLOSE_CHEVRON_GAP + CHEVRON_SIZE;
        _drawChevronDown(dc, cx, _closeChevronY, CHEVRON_SIZE);
    }

    // Measures then draws 1-2 fields as one centered inline line: "Label value" per field, fields separated by a wider gap - mirrors _drawSegmentedLine's group-centering, just with a label prefix per segment.
    private function _drawGridRow(
        dc as Dc,
        cx as Number,
        y as Number,
        row as Array<[String, String, Number]>
    ) as Void {
        var labelWidths = [] as Array<Number>;
        var valueWidths = [] as Array<Number>;
        var totalW = -FIELD_GAP_PX;
        for (var i = 0; i < row.size(); i++) {
            var cell = row[i];
            var labelW = dc.getTextDimensions(cell[0] as String, _fontTiny)[0];
            var valueW = _valueSegmentWidth(dc, cell[1] as String);
            labelWidths.add(labelW);
            valueWidths.add(valueW);
            totalW += labelW + LABEL_VALUE_GAP_PX + valueW + FIELD_GAP_PX;
        }

        var x = cx - totalW / 2;
        for (var i = 0; i < row.size(); i++) {
            var cell = row[i];
            dc.setColor(COLOR_ROW_LABEL, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                x,
                y,
                _fontTiny,
                cell[0] as String,
                Graphics.TEXT_JUSTIFY_LEFT
            );
            x += (labelWidths[i] as Number) + LABEL_VALUE_GAP_PX;
            _drawValueSegment(dc, x, y, cell[1] as String, cell[2] as Number);
            x += (valueWidths[i] as Number) + FIELD_GAP_PX;
        }
    }

    private function _valueSegmentWidth(dc as Dc, value as String) as Number {
        var markIdx = value.find(DEGREE_MARK);
        if (markIdx == null) {
            return dc.getTextDimensions(value, _fontTiny)[0];
        }
        var idx = markIdx as Number;
        var before = value.substring(0, idx) as String;
        var after = value.substring(idx + 1, value.length()) as String;
        var beforeW = dc.getTextDimensions(before, _fontTiny)[0];
        var afterW =
            after.length() > 0 ? dc.getTextDimensions(after, _fontTiny)[0] : 0;
        var markW =
            DEGREE_MARK_GAP_LEFT +
            DEGREE_MARK_R * 2 +
            (after.length() > 0 ? DEGREE_MARK_GAP_RIGHT : 0);
        return beforeW + markW + afterW;
    }

    // Left-justified draw starting at x - the caller (_drawGridRow) already handled centering the whole row.
    private function _drawValueSegment(
        dc as Dc,
        x as Number,
        y as Number,
        value as String,
        color as Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var markIdx = value.find(DEGREE_MARK);
        if (markIdx == null) {
            dc.drawText(x, y, _fontTiny, value, Graphics.TEXT_JUSTIFY_LEFT);
            return;
        }

        var idx = markIdx as Number;
        var before = value.substring(0, idx) as String;
        var after = value.substring(idx + 1, value.length()) as String;
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

    private function _drawChevronDown(
        dc as Dc,
        x as Number,
        y as Number,
        s as Number
    ) as Void {
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x - s, y - s, x, y);
        dc.drawLine(x, y, x + s, y - s);
    }
}

class AircraftDetailDelegate extends WatchUi.BehaviorDelegate {
    private var _view as AircraftDetailView;
    private var _radarView as RadarView;
    private var _dragLastY as Number?;
    private const SCROLL_STEP_PX = 40;

    public function initialize(view as AircraftDetailView, radarView as RadarView) {
        BehaviorDelegate.initialize();
        _view = view;
        _radarView = radarView;
    }

    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();
        if (key == WatchUi.KEY_UP) {
            _view.scroll(-SCROLL_STEP_PX);
            return true;
        } else if (key == WatchUi.KEY_DOWN) {
            _view.scroll(SCROLL_STEP_PX);
            return true;
        } else if (key == WatchUi.KEY_ESC) {
            _close();
            return true;
        }
        return false;
    }

    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        if (_view.isCloseChevronHit(coords[0], coords[1])) {
            _close();
            return true;
        }
        return false;
    }

    public function onDrag(dragEvent as WatchUi.DragEvent) as Boolean {
        var coords = dragEvent.getCoordinates();
        var type = dragEvent.getType();

        if (type == WatchUi.DRAG_TYPE_START) {
            _dragLastY = coords[1];
        } else if (type == WatchUi.DRAG_TYPE_CONTINUE) {
            var last = _dragLastY;
            if (last != null) {
                _view.scroll((last as Number) - coords[1]);
            }
            _dragLastY = coords[1];
        } else if (type == WatchUi.DRAG_TYPE_STOP) {
            _dragLastY = null;
        }
        return true;
    }

    private function _close() as Void {
        _radarView.onDetailClosed();
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
