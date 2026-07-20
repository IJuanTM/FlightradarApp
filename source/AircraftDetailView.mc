import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Custom full-screen view, not a system Menu2 - RadarView builds the row data and passes its own ring/panel geometry.
class AircraftDetailView extends WatchUi.View {
    private var _headerText as String;
    private var _headerColor as Number;
    private var _rows as Array<Array<[String, String, Number]> >;
    private var _depRowIndex as Number;
    private var _arrRowIndex as Number;
    // True at row i if row i starts a new visual group - those get a bigger gap than rows within the same group.
    private var _groupStarts as Array<Boolean>;
    private var _scrollPx as Number = 0;
    private var _fontTiny as Graphics.FontType = Graphics.FONT_XTINY;
    private var _fontSmall as Graphics.FontType = Graphics.FONT_SMALL;

    private var _ringCx as Number;
    private var _ringCy as Number;
    private var _ringRadiusPx as Number;
    private var _topY as Number;
    private var _bottomY as Number = 0;
    private var _bottomPanelH as Number;

    // Adaptive: stretches toward MAX for few rows, clamps to MIN and scrolls for many. Between-group gap only.
    private var _rowHeight as Number = 20;
    // Precomputed per-row Y offset from a 0-based origin, built once in onLayout.
    private var _rowY as Array<Number> = [];
    private var _totalContentHeight as Number = 0;
    private var _contentTop as Number = 0;
    private var _visibleHeight as Number = 1;
    private var _closeChevronY as Number = 0;

    // Measured once in onLayout from the monospace font - same _charW pattern as ../TerminalWatchface.
    private var _charW as Number = 8;
    private var _charH as Number = 14;
    private var _minRowHeight as Number = 20;
    private var _maxRowHeight as Number = 28;
    private var _contentPadding as Number = 6;
    // Gap between rows in the same group - text height plus a small pad, always tighter than _rowHeight.
    private var _intraGroupGapPaddingPx as Number = 2;
    private const COLOR_ROW_LABEL = 0x999999;

    // Must match RadarView's own values - duplicated since this class can't see RadarView's private consts.
    private const COLOR_RING = 0xaaaaaa;
    private const COLOR_BOUNDARY_ALPHA = 0x40;
    private const COLOR_WHITE = 0xffffff;
    private const COLOR_VALUE_DIM = 0x555555;

    // Each row draws as one centered inline line, same style as the compact panel's segmented line.
    private var _labelValueGapPx as Number = 4;
    private var _fieldGapPx as Number = 16;

    private const CHEVRON_SIZE = 7;
    private const CHEVRON_TAP_PAD = 16;

    public function initialize(
        headerText as String,
        headerColor as Number,
        rows as Array<Array<[String, String, Number]> >,
        depRowIndex as Number,
        arrRowIndex as Number,
        groupStarts as Array<Boolean>,
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
        _depRowIndex = depRowIndex;
        _arrRowIndex = arrRowIndex;
        _groupStarts = groupStarts;
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

        var charSize = DrawUtil.measureChar(dc, _fontTiny);
        _charW = charSize[0];
        _charH = charSize[1];
        _minRowHeight = _charH + 6;
        _maxRowHeight = _charH + 14;
        _contentPadding = _charH / 2;
        _intraGroupGapPaddingPx = _charW / 4;
        _labelValueGapPx = _charW;
        _fieldGapPx = _charW * 2;

        var h = dc.getHeight();
        _bottomY = h - _bottomPanelH;

        var contentTop0 = _topY + _contentPadding;
        var available = _bottomY - _contentPadding - contentTop0;
        var count = _rows.size();
        var rowH = count > 0 ? available / count : _minRowHeight;
        if (rowH < _minRowHeight) {
            rowH = _minRowHeight;
        } else if (rowH > _maxRowHeight) {
            rowH = _maxRowHeight;
        }
        _rowHeight = rowH;
        _visibleHeight = available;

        var lineH = dc.getTextDimensions("Ag", _fontTiny)[1];
        var intraGap = lineH + _intraGroupGapPaddingPx;

        // Precomputed once - rowH at a group boundary, intraGap within the same group.
        _rowY = [];
        var y = 0;
        for (var i = 0; i < count; i++) {
            if (i > 0) {
                var isGroupStart = i < _groupStarts.size() && _groupStarts[i];
                y += isGroupStart ? rowH : intraGap;
            }
            _rowY.add(y);
        }

        // Real content height, not count*rowH - excludes the trailing gap after the last row.
        var used = count > 0 ? y + lineH : 0;
        _totalContentHeight = used;
        _contentTop =
            used < available
                ? contentTop0 + (available - used) / 2
                : contentTop0;
    }

    // Departure/arrival update independently - each is its own async lookup, resolving at different times.
    public function setDepartureText(text as String, color as Number) as Void {
        _setRowText(_depRowIndex, text, color);
        WatchUi.requestUpdate();
    }

    public function setArrivalText(text as String, color as Number) as Void {
        _setRowText(_arrRowIndex, text, color);
        WatchUi.requestUpdate();
    }

    private function _setRowText(
        rowIndex as Number,
        text as String,
        color as Number
    ) as Void {
        if (rowIndex < 0 || rowIndex >= _rows.size()) {
            return;
        }
        var row = _rows[rowIndex];
        var cell = row[0];
        row[0] = [cell[0], text, color];
    }

    public function scroll(dyPx as Number) as Void {
        _scrollPx += dyPx;
        var maxScroll = _totalContentHeight - _visibleHeight;
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

    // Tap target for the down chevron - kept generous since it's a small glyph.
    public function isCloseChevronHit(x as Number, y as Number) as Boolean {
        return (
            (x - _ringCx).abs() <= CHEVRON_TAP_PAD &&
            (y - _closeChevronY).abs() <= CHEVRON_TAP_PAD
        );
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        // Same boundary ring the radar draws - covered by the black bands below, visible only in the content band.
        dc.setStroke(DrawUtil.withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawCircle(_ringCx, _ringCy, _ringRadiusPx);

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, w, _topY);
        // Starts one row below _bottomY - leaves that pixel unerased so the separator sits on it, not bare black.
        // Mirrors the top band, which stops one row short of _topY for the same reason.
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
            var y = _contentTop + (_rowY[i] as Number) - _scrollPx;
            if (y + _rowHeight < _contentTop || y > _bottomY) {
                continue;
            }
            _drawGridRow(dc, cx, y, _rows[i]);
        }

        _drawCloseAffordance(dc, cx, h);
    }

    // Width clamped to the boundary ring's chord at that height, so it touches the ring on both ends.
    private function _drawRingSeparator(dc as Dc, y as Number) as Void {
        var dy = (y - _ringCy).abs();
        if (dy >= _ringRadiusPx) {
            return;
        }
        var halfW = DrawUtil.chordHalfExtent(_ringRadiusPx, dy);
        // COLOR_BOUNDARY_ALPHA, not a dimmer tone - reads as a continuation of the boundary ring itself.
        dc.setStroke(DrawUtil.withAlpha(COLOR_RING, COLOR_BOUNDARY_ALPHA));
        dc.drawLine(_ringCx - halfW, y, _ringCx + halfW, y);
    }

    // Just the down chevron, centered in the band below _bottomY - no text label, reads as an affordance not body text.
    private function _drawCloseAffordance(
        dc as Dc,
        cx as Number,
        h as Number
    ) as Void {
        var bandH = h - _bottomY;
        _closeChevronY = _bottomY + bandH / 2;
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        _drawChevronDown(dc, cx, _closeChevronY, CHEVRON_SIZE);
    }

    // Measures then draws 1-2 "Label value" fields as one centered inline line, mirroring _drawSegmentedLine.
    private function _drawGridRow(
        dc as Dc,
        cx as Number,
        y as Number,
        row as Array<[String, String, Number]>
    ) as Void {
        var labelWidths = [] as Array<Number>;
        var valueWidths = [] as Array<Number>;
        var totalW = -_fieldGapPx;
        for (var i = 0; i < row.size(); i++) {
            var cell = row[i];
            var labelW = dc.getTextDimensions(cell[0] as String, _fontTiny)[0];
            var valueW = _valueSegmentWidth(dc, cell[1] as String);
            labelWidths.add(labelW);
            valueWidths.add(valueW);
            totalW += labelW + _labelValueGapPx + valueW + _fieldGapPx;
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
            x += (labelWidths[i] as Number) + _labelValueGapPx;
            _drawValueSegment(dc, x, y, cell[1] as String, cell[2] as Number);
            x += (valueWidths[i] as Number) + _fieldGapPx;
        }
    }

    private function _valueSegmentWidth(dc as Dc, value as String) as Number {
        return DrawUtil.dimSplitTextWidth(dc, _fontTiny, value);
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
        DrawUtil.drawDimSplitText(
            dc,
            x,
            y,
            _fontTiny,
            value,
            color,
            COLOR_VALUE_DIM
        );
    }

    private function _drawChevronDown(
        dc as Dc,
        x as Number,
        y as Number,
        s as Number
    ) as Void {
        dc.setColor(COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        DrawUtil.drawChevron(dc, x, y, s, false);
    }
}

class AircraftDetailDelegate extends WatchUi.BehaviorDelegate {
    private var _view as AircraftDetailView;
    private var _radarView as RadarView;
    private var _dragLastY as Number?;
    private const SCROLL_STEP_PX = 40;

    public function initialize(
        view as AircraftDetailView,
        radarView as RadarView
    ) {
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
