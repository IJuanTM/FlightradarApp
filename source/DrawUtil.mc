import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

module DrawUtil {
    // [text, color, glyph, suffix] - glyph is a code-drawn :degree/:warning mark the fonts lack, or null.
    typedef ValueRun as [String, Number, Symbol?, String];

    // Right biased larger - digits carry more right-side bearing than letters carry left-side.
    const DEGREE_MARK_GAP_LEFT = 1;
    const DEGREE_MARK_GAP_RIGHT = 2;
    const DEGREE_MARK_R = 1;
    // Text y is the glyph box's top, not center - nudges the circle down to the text's visual middle.
    const DEGREE_MARK_Y_OFFSET = 4;

    const WARNING_MARK_R = 4;

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
    const ALPHA_95 = 0xf2;

    // Boundary ring color, shared so RadarView's compact ring and AircraftDetailView's full-screen ring match.
    const COLOR_RING = 0xaaaaaa;
    const COLOR_BOUNDARY_ALPHA = ALPHA_50;

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

    // Returns the same width runWidth() would, from the measurements drawing already needed.
    function drawRun(
        dc as Dc,
        x as Number,
        y as Number,
        font,
        run as ValueRun
    ) as Number {
        var before = run[0] as String;
        var color = run[1] as Number;
        var glyph = run[2] as Symbol?;
        var after = run[3] as String;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, before, Graphics.TEXT_JUSTIFY_LEFT);
        var beforeW = dc.getTextDimensions(before, font)[0];
        if (glyph == null) {
            return beforeW;
        }

        var afterX;
        if (glyph == :degree) {
            var circleCx = x + beforeW + DEGREE_MARK_GAP_LEFT + DEGREE_MARK_R;
            dc.drawCircle(
                circleCx,
                y + DEGREE_MARK_R + DEGREE_MARK_Y_OFFSET,
                DEGREE_MARK_R
            );
            if (after.length() == 0) {
                return circleCx + DEGREE_MARK_R - x;
            }
            afterX = circleCx + DEGREE_MARK_R + DEGREE_MARK_GAP_RIGHT;
        } else {
            var iconCx = x + beforeW + WARNING_MARK_R;
            drawWarningIcon(
                dc,
                iconCx,
                y + dc.getTextDimensions("0", font)[1] / 2,
                WARNING_MARK_R,
                color
            );
            afterX = iconCx + WARNING_MARK_R;
            if (after.length() == 0) {
                return afterX - x;
            }
        }
        dc.drawText(afterX, y, font, after, Graphics.TEXT_JUSTIFY_LEFT);
        return afterX - x + dc.getTextDimensions(after, font)[0];
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
            x += drawRun(dc, x, y, font, runs[i]);
        }
    }

    function _wordsInRun(s as String) as Array<String> {
        var chars = s.toCharArray();
        var words = [] as Array<String>;
        var start = -1;
        for (var i = 0; i < chars.size(); i++) {
            if (chars[i] == ' ') {
                if (start >= 0) {
                    words.add(s.substring(start, i) as String);
                    start = -1;
                }
            } else if (start < 0) {
                start = i;
            }
        }
        if (start >= 0) {
            words.add(s.substring(start, chars.size()) as String);
        }
        return words;
    }

    // A glyph/suffix (degree mark etc.) stays attached to its run's last word, never split mid-run.
    function wrapSegments(
        dc as Dc,
        font,
        runs as Array<ValueRun>,
        maxWidthPx as Number
    ) as Array<Array<ValueRun> > {
        var words = [] as Array<ValueRun>;
        for (var i = 0; i < runs.size(); i++) {
            var run = runs[i];
            var parts = _wordsInRun(run[0] as String);
            for (var j = 0; j < parts.size(); j++) {
                var isLast = j == parts.size() - 1;
                words.add(
                    [
                        parts[j],
                        run[1] as Number,
                        isLast ? run[2] as Symbol? : null,
                        isLast ? run[3] as String : "",
                    ] as ValueRun
                );
            }
        }

        var lines = [] as Array<Array<ValueRun> >;
        var line = [] as Array<ValueRun>;
        var lineW = 0;
        var spaceW = dc.getTextDimensions(" ", font)[0];
        for (var i = 0; i < words.size(); i++) {
            var w = words[i];
            var wordW = runWidth(dc, font, w);
            var addW = (line.size() > 0 ? spaceW : 0) + wordW;
            if (line.size() > 0 && lineW + addW > maxWidthPx) {
                lines.add(line);
                line = [] as Array<ValueRun>;
                lineW = 0;
                addW = wordW;
            }
            line.add(
                line.size() > 0 ? [" " + w[0], w[1], w[2], w[3]] as ValueRun : w
            );
            lineW += addW;
        }
        if (line.size() > 0) {
            lines.add(line);
        }
        return lines;
    }

    // The cutout is plain black (the canvas always is); dc is left set to `color` so callers needn't reset it.
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
        dc.drawLine(cx, cy - (halfSize * 0.5).toNumber(), cx, dotY - 2);
        dc.fillCircle(cx, dotY, 1);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
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
