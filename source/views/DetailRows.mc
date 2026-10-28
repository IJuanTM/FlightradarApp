import Toybox.Lang;

module DetailRows {
    typedef Cell as [String, Array<DrawUtils.ValueRun>];
    // [rows, departureRowIndex, arrivalRowIndex, groupStarts] - the AircraftDetailView constructor's content arguments.
    typedef Full as [Array<Array<Cell> >, Number, Number, Array<Boolean>];

    // Curated, not exhaustive - the rest lives in full() to keep the compact panel short.
    function compact(
        ac as Aircraft,
        idColor as Number,
        trackLoading as Boolean,
        trackLoaded as Boolean
    ) as Array<Array<DrawUtils.ValueRun> > {
        var lines = [] as Array<Array<DrawUtils.ValueRun> >;

        // Emergency only - safety-critical, always the first thing shown, not buried below alt/speed/heading.
        if (ac.isEmergency()) {
            var label =
                ac.squawk != null
                    ? "EMERG " + (ac.squawk as String)
                    : "EMERGENCY";
            lines.add([DrawUtils.plainRun(label, Palette.EMERGENCY)]);
        }

        var idSegs = [] as Array<DrawUtils.ValueRun>;
        idSegs.add(
            DrawUtils.plainRun(
                ac.flight != null && (ac.flight as String).length() > 0
                    ? ac.flight as String
                    : ac.hex,
                idColor
            )
        );
        if (ac.registration != null) {
            idSegs.add(
                DrawUtils.plainRun(ac.registration as String, Palette.IDENTITY)
            );
        }
        var badge = _statusBadge(ac);
        if (badge != null) {
            idSegs.add(DrawUtils.plainRun(badge, _statusColor(ac)));
        }
        lines.add(idSegs);

        var typeStr =
            ac.typeDesc != null
                ? ac.typeDesc as String
                : ac.typeCode != null
                  ? ac.typeCode as String
                  : "";
        if (typeStr.length() > 0) {
            lines.add([DrawUtils.plainRun(typeStr, Palette.IDENTITY)]);
        }

        var statSegs = [] as Array<DrawUtils.ValueRun>;
        if (ac.onGround) {
            statSegs.add(DrawUtils.plainRun("GND", Palette.ALT));
        } else if (ac.altBaro != null) {
            statSegs.add(
                DrawUtils.plainRun(
                    Formatters.altitude(ac.altBaro as Number),
                    Palette.ALT
                )
            );
        }
        if (ac.gs != null) {
            statSegs.add(
                DrawUtils.plainRun(
                    Formatters.speedKt(NumUtils.round(ac.gs as Float)),
                    Palette.SPEED
                )
            );
        }
        if (ac.heading != null) {
            statSegs.add(
                [
                    NumUtils.roundHeading(ac.heading as Float).toString(),
                    Palette.HDG,
                    :degree,
                    "",
                ] as DrawUtils.ValueRun
            );
        }
        if (statSegs.size() > 0) {
            lines.add(statSegs);
        }

        var trackStatus = "";
        var trackColor = Palette.GRID_LABEL;
        if (trackLoading) {
            trackStatus = "Loading Track...";
        } else if (trackLoaded) {
            trackStatus = "Track Loaded";
            trackColor = Palette.SUCCESS;
        } else {
            trackStatus = "No Track History";
        }
        lines.add([DrawUtils.plainRun(trackStatus, trackColor)]);

        return lines;
    }

    // Long identity text (type/operator) gets its own row; only short, similar stats share one.
    function full(ac as Aircraft) as Full {
        var rows = [] as Array<Array<Cell> >;
        // Row indices where a new visual group begins - converted to a per-row Boolean array at the end.
        var groupBoundaries = [] as Array<Number>;

        var identityStart = rows.size();
        _gridRow(
            rows,
            _cellOrDash("Registration", ac.registration, Palette.IDENTITY),
            _cell("Hex", ac.hex, Palette.IDENTITY)
        );

        _gridRow(
            rows,
            _cellOrDash(
                "Type",
                ac.typeDesc != null ? ac.typeDesc : ac.typeCode,
                Palette.IDENTITY
            ),
            _cellOrDash("Category", ac.category, Palette.IDENTITY)
        );

        rows.add([_cellOrDash("Operator", ac.operatorName, Palette.IDENTITY)]);
        _markGroupIfNonEmpty(rows, groupBoundaries, identityStart);

        var performanceStart = rows.size();
        var altText = ac.onGround
            ? "GND"
            : ac.altBaro != null
              ? Formatters.altitude(ac.altBaro as Number)
              : null;
        var vertRateCell = _cell("Vertical Rate", "-", Palette.ROUTE_DIM);
        if (ac.vertRate != null) {
            var fpm = NumUtils.round(ac.vertRate as Float);
            vertRateCell = _cell(
                "Vertical Rate",
                (fpm > 0 ? "+" : "") + Formatters.vertRate(fpm),
                fpm > 0
                    ? Palette.SUCCESS
                    : fpm < 0
                      ? Palette.WARN
                      : Palette.DETAIL_VALUE
            );
        }
        _gridRow(
            rows,
            _cellOrDash("Altitude", altText, Palette.ALT),
            vertRateCell
        );

        _gridRow(
            rows,
            _cellOrDash(
                "Ground Speed",
                ac.gs != null
                    ? Formatters.speedKt(NumUtils.round(ac.gs as Float))
                    : null,
                Palette.SPEED
            ),
            _cellOrDash(
                "IAS",
                ac.ias != null ? Formatters.speedKt(ac.ias as Number) : null,
                Palette.SPEED
            )
        );

        _gridRow(
            rows,
            _cellOrDash(
                "TAS",
                ac.tas != null
                    ? Formatters.speedKt(NumUtils.round(ac.tas as Float))
                    : null,
                Palette.SPEED
            ),
            _cellOrDash(
                "Mach",
                ac.mach != null ? (ac.mach as Float).format("%.2f") : null,
                Palette.SPEED
            )
        );
        _markGroupIfNonEmpty(rows, groupBoundaries, performanceStart);

        var navStatusStart = rows.size();
        var emergency = ac.isEmergency();
        var hdgCell = _degreeCellOrDash(
            "Heading",
            ac.heading != null
                ? NumUtils.roundHeading(ac.heading as Float).toString()
                : null,
            Palette.HDG,
            ""
        );
        var squawkColor = emergency ? Palette.EMERGENCY : Palette.SQUAWK;
        // Full space before the icon, not DrawUtils's own small fixed gap.
        var squawkCell = emergency
            ? [
                  "Squawk",
                  [
                      [
                          (ac.squawk != null ? ac.squawk as String : "") + " ",
                          squawkColor,
                          :warning,
                          "",
                      ] as DrawUtils.ValueRun,
                  ],
              ] as Cell
            : _cellOrDash("Squawk", ac.squawk, squawkColor);
        _gridRow(rows, hdgCell, squawkCell);

        var status = _statusBadge(ac);
        if (status != null) {
            rows.add([_cell("Status", status, _statusColor(ac))]);
        }
        _markGroupIfNonEmpty(rows, groupBoundaries, navStatusStart);

        var targetStart = rows.size();
        _gridRow(
            rows,
            _cellOrDash(
                "Selected Alt",
                ac.navAltitude != null
                    ? Formatters.altitude(ac.navAltitude as Number)
                    : null,
                Palette.DETAIL_VALUE
            ),
            _degreeCellOrDash(
                "Selected Hdg",
                ac.navHeading != null
                    ? NumUtils.roundHeading(ac.navHeading as Float).toString()
                    : null,
                Palette.DETAIL_VALUE,
                ""
            )
        );
        _markGroupIfNonEmpty(rows, groupBoundaries, targetStart);

        var envStart = rows.size();
        rows.add([
            _degreeCellOrDash(
                "Wind",
                ac.windDir != null && ac.windSpeed != null
                    ? (ac.windDir as Number).toString()
                    : null,
                Palette.ENV,
                ac.windSpeed != null
                    ? " @ " + Formatters.speedKt(ac.windSpeed as Number)
                    : ""
            ),
        ]);

        _gridRow(
            rows,
            _degreeCellOrDash(
                "Outside Temp",
                ac.outsideAirTemp != null
                    ? (ac.outsideAirTemp as Number).toString()
                    : null,
                Palette.ENV,
                "C"
            ),
            _degreeCellOrDash(
                "Total Air Temp",
                ac.totalAirTemp != null
                    ? (ac.totalAirTemp as Number).toString()
                    : null,
                Palette.ENV,
                "C"
            )
        );
        _markGroupIfNonEmpty(rows, groupBoundaries, envStart);

        // Separate rows, not one joined "dep -> arr" line - a full description is too long for one line.
        var routeStart = rows.size();
        rows.add([_cell("Departure", "Loading...", Palette.ROUTE_DIM)]);
        var depIndex = rows.size() - 1;
        rows.add([_cell("Arrival", "Loading...", Palette.ROUTE_DIM)]);
        var arrIndex = rows.size() - 1;
        _markGroupIfNonEmpty(rows, groupBoundaries, routeStart);

        var groupStarts = [] as Array<Boolean>;
        for (var i = 0; i < rows.size(); i++) {
            groupStarts.add(false);
        }
        for (var i = 0; i < groupBoundaries.size(); i++) {
            groupStarts[groupBoundaries[i] as Number] = true;
        }

        return [rows, depIndex, arrIndex, groupStarts] as Full;
    }

    function _cell(label as String, text as String, color as Number) as Cell {
        return [label, DrawUtils.plainRuns(text, color)] as Cell;
    }

    function _degreeCell(
        label as String,
        text as String,
        color as Number,
        suffix as String
    ) as Cell {
        return (
            [label, [[text, color, :degree, suffix] as DrawUtils.ValueRun]] as
            Cell
        );
    }

    function _cellOrDash(
        label as String,
        text as String?,
        color as Number
    ) as Cell {
        return text != null
            ? _cell(label, text, color)
            : _cell(label, "-", Palette.ROUTE_DIM);
    }

    function _degreeCellOrDash(
        label as String,
        text as String?,
        color as Number,
        suffix as String
    ) as Cell {
        return text != null
            ? _degreeCell(label, text, color, suffix)
            : _cell(label, "-", Palette.ROUTE_DIM);
    }

    function _gridRow(
        rows as Array<Array<Cell> >,
        cellA as Cell,
        cellB as Cell
    ) as Void {
        rows.add([cellA, cellB]);
    }

    function _statusBadge(ac as Aircraft) as String? {
        var parts = [] as Array<String>;
        if (ac.spi) {
            parts.add("IDENT");
        }
        if (ac.alertFlag) {
            parts.add("ALERT");
        }
        return parts.size() > 0 ? " ".join(parts) : null;
    }

    function _statusColor(ac as Aircraft) as Number {
        return ac.isEmergency() ? Palette.EMERGENCY : Palette.WARN;
    }

    // A group that added no rows (all its fields were absent) doesn't get a boundary marker.
    function _markGroupIfNonEmpty(
        rows as Array<Array<Cell> >,
        groupBoundaries as Array<Number>,
        start as Number
    ) as Void {
        if (rows.size() > start) {
            groupBoundaries.add(start);
        }
    }
}
