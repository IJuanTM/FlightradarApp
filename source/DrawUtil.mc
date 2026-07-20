import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

// Stateless drawing-geometry helpers shared between RadarView and AircraftDetailView.
module DrawUtil {
    // One same-colored run of text, with an optional code-drawn glyph (this app's fonts have no "°" glyph
    // or warning triangle) inserted after `text` and before `suffix` - e.g. ["270", COLOR_HDG, :degree, ""]
    // or ["1200 ", color, :warning, ""]. glyph is null for a plain run.
    typedef ValueRun as [String, Number, Symbol?, String];

    // Right biased larger - digits carry more right-side bearing than letters carry left-side.
    const DEGREE_MARK_GAP_LEFT = 1;
    const DEGREE_MARK_GAP_RIGHT = 2;
    const DEGREE_MARK_R = 1;
    // Text y is the glyph box's top, not center - nudges the circle down to the text's visual middle.
    const DEGREE_MARK_Y_OFFSET = 4;

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

    // The only opacities used anywhere in this app.
    const ALPHA_15 = 0x26;
    const ALPHA_25 = 0x40;
    const ALPHA_35 = 0x59;
    const ALPHA_50 = 0x80;
    const ALPHA_55 = 0x8c;
    const ALPHA_75 = 0xc0;
    const ALPHA_95 = 0xf2;

    // [charW, charH] for a monospace font - one character's width is every character's width.
    function measureChar(dc as Dc, font) as [Number, Number] {
        return (
            [dc.getTextWidthInPixels("0", font), dc.getFontHeight(font)] as
            [Number, Number]
        );
    }

    function plainRun(text as String, color as Number) as ValueRun {
        return [text, color, null, ""] as ValueRun;
    }

    function plainRuns(text as String, color as Number) as Array<ValueRun> {
        return [plainRun(text, color)] as Array<ValueRun>;
    }

    function runWidth(dc as Dc, font, run as ValueRun) as Number {
        var before = run[0] as String;
        var glyph = run[2] as Symbol?;
        var after = run[3] as String;
        if (glyph == null) {
            return dc.getTextDimensions(before, font)[0];
        }
        var beforeW = dc.getTextDimensions(before, font)[0];
        var afterW =
            after.length() > 0 ? dc.getTextDimensions(after, font)[0] : 0;
        var glyphW =
            glyph == :degree
                ? DEGREE_MARK_GAP_LEFT +
                  DEGREE_MARK_R * 2 +
                  (after.length() > 0 ? DEGREE_MARK_GAP_RIGHT : 0)
                : WARNING_MARK_R * 2;
        return beforeW + glyphW + afterW;
    }

    function drawRun(
        dc as Dc,
        x as Number,
        y as Number,
        font,
        run as ValueRun
    ) as Void {
        var before = run[0] as String;
        var color = run[1] as Number;
        var glyph = run[2] as Symbol?;
        var after = run[3] as String;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, before, Graphics.TEXT_JUSTIFY_LEFT);
        if (glyph == null) {
            return;
        }
        var beforeW = dc.getTextDimensions(before, font)[0];

        if (glyph == :degree) {
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

    // Runs drawn contiguously - a dim-split value like "KJFK" + dim " (no info)" is just two runs.
    function segmentsWidth(dc as Dc, font, runs as Array<ValueRun>) as Number {
        var w = 0;
        for (var i = 0; i < runs.size(); i++) {
            w += runWidth(dc, font, runs[i]);
        }
        return w;
    }

    function drawSegments(
        dc as Dc,
        x as Number,
        y as Number,
        font,
        runs as Array<ValueRun>
    ) as Void {
        for (var i = 0; i < runs.size(); i++) {
            drawRun(dc, x, y, font, runs[i]);
            x += runWidth(dc, font, runs[i]);
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
