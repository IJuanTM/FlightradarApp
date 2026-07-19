import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

// Stateless drawing-geometry helpers shared between RadarView and AircraftDetailView.
module DrawUtil {
    // Marks where a code-drawn degree circle goes - this app's fonts have no "°" glyph.
    const DEGREE_MARK = "^";
    // Right biased larger - digits carry more right-side bearing than letters carry left-side.
    const DEGREE_MARK_GAP_LEFT = 1;
    const DEGREE_MARK_GAP_RIGHT = 2;
    const DEGREE_MARK_R = 1;
    // Text y is the glyph box's top, not center - nudges the circle down to the text's visual middle.
    const DEGREE_MARK_Y_OFFSET = 4;

    // Marks where a code-drawn warning icon goes - never collides with DEGREE_MARK, no value has both.
    const WARNING_MARK = "!";
    const WARNING_MARK_R = 4;

    // Half-length of the chord of a circle of the given radius at a given perpendicular offset from center.
    function chordHalfExtent(radiusPx as Number, offsetPx as Number) as Number {
        return Math.sqrt(
            (radiusPx * radiusPx - offsetPx * offsetPx).toFloat()
        ).toNumber();
    }

    function withAlpha(color as Number, alpha as Number) as Number {
        return (alpha << 24) | (color & 0xffffff);
    }

    // [charW, charH] for a monospace font - one character's width is every character's width.
    function measureChar(dc as Dc, font) as [Number, Number] {
        return (
            [dc.getTextWidthInPixels("0", font), dc.getFontHeight(font)] as
            [Number, Number]
        );
    }

    // Locates whichever embedded marker (if any) is present - a value never contains both kinds.
    function _findMarker(text as String) as [Number, String]? {
        var d = text.find(DEGREE_MARK);
        if (d != null) {
            return [d as Number, DEGREE_MARK];
        }
        var w = text.find(WARNING_MARK);
        if (w != null) {
            return [w as Number, WARNING_MARK];
        }
        return null;
    }

    function markedTextWidth(dc as Dc, font, text as String) as Number {
        var found = _findMarker(text);
        if (found == null) {
            return dc.getTextDimensions(text, font)[0];
        }
        var idx = (found as [Number, String])[0];
        var kind = (found as [Number, String])[1];
        var before = text.substring(0, idx) as String;
        var after = text.substring(idx + 1, text.length()) as String;
        var beforeW = dc.getTextDimensions(before, font)[0];
        var afterW =
            after.length() > 0 ? dc.getTextDimensions(after, font)[0] : 0;
        var markW = kind.equals(DEGREE_MARK)
            ? DEGREE_MARK_GAP_LEFT +
              DEGREE_MARK_R * 2 +
              (after.length() > 0 ? DEGREE_MARK_GAP_RIGHT : 0)
            : WARNING_MARK_R * 2;
        return beforeW + markW + afterW;
    }

    // color is only needed for the warning-icon branch, which resets color twice internally (fill, then cutout).
    function drawMarkedText(
        dc as Dc,
        x as Number,
        y as Number,
        font,
        text as String,
        color as Number
    ) as Void {
        var found = _findMarker(text);
        if (found == null) {
            dc.drawText(x, y, font, text, Graphics.TEXT_JUSTIFY_LEFT);
            return;
        }

        var idx = (found as [Number, String])[0];
        var kind = (found as [Number, String])[1];
        var before = text.substring(0, idx) as String;
        var after = text.substring(idx + 1, text.length()) as String;
        dc.drawText(x, y, font, before, Graphics.TEXT_JUSTIFY_LEFT);
        var beforeW = dc.getTextDimensions(before, font)[0];

        if (kind.equals(DEGREE_MARK)) {
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
                    font,
                    after,
                    Graphics.TEXT_JUSTIFY_LEFT
                );
            }
            return;
        }

        var iconCx = x + beforeW + WARNING_MARK_R;
        var textH = dc.getTextDimensions("0", font)[1];
        drawWarningIcon(dc, iconCx, y + textH / 2, WARNING_MARK_R, color);
        // Text drawn after the icon needs its own color restored - drawWarningIcon leaves dc's color set to black.
        if (after.length() > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                iconCx + WARNING_MARK_R,
                y,
                font,
                after,
                Graphics.TEXT_JUSTIFY_LEFT
            );
        }
    }

    // Filled triangle with a black cutout exclamation mark - canvas is always black, so no color sampling needed.
    function drawWarningIcon(
        dc as Dc,
        cx as Number,
        cy as Number,
        halfSize as Number,
        color as Number
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([
            [cx, cy - halfSize],
            [cx - halfSize, cy + halfSize],
            [cx + halfSize, cy + halfSize],
        ]);
        // Fixed 1px stem/dot (not scaled with halfSize) - drawLine keeps the stem exactly centered on cx.
        dc.setColor(0x000000, Graphics.COLOR_TRANSPARENT);
        var dotY = cy + halfSize - 2;
        var stemBottom = dotY - 2;
        dc.drawLine(cx, cy - (halfSize * 0.5).toNumber(), cx, stemBottom);
        dc.fillCircle(cx, dotY, 1);
    }

    // Two-line chevron ("^" or "v"), vertex at (x,y) - caller sets color first. pointUp=true draws pointing up.
    function drawChevron(
        dc as Dc,
        x as Number,
        y as Number,
        s as Number,
        pointUp as Boolean
    ) as Void {
        var dy = pointUp ? s : -s;
        dc.drawLine(x - s, y + dy, x, y);
        dc.drawLine(x, y, x + s, y + dy);
    }
}
