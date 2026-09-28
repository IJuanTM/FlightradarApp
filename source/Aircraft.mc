import Toybox.Lang;

class Aircraft {
    public var hex as String;
    public var flight as String?;
    public var lat as Float;
    public var lon as Float;
    public var altBaro as Number?;
    public var onGround as Boolean;
    public var gs as Float?;
    public var track as Float?;
    // Heading, not track, drives icon rotation - it stays valid at zero groundspeed, where the feed omits track.
    public var heading as Float?;
    public var category as String?;
    public var registration as String?;
    public var typeCode as String?;
    public var typeDesc as String?;
    public var military as Boolean;
    public var vertRate as Float?;
    public var squawk as String?;
    public var tas as Float?;
    public var emergency as String?;
    public var navAltitude as Number?;
    public var navHeading as Float?;
    // Seconds since the last position update - seen_pos when available, else the coarser seen (any message).
    public var positionAgeSec as Float?;
    public var operatorName as String?;
    public var ias as Number?;
    public var mach as Float?;
    // Ident button pressed / flight-status-change flag - distinct from emergency.
    public var spi as Boolean;
    public var alertFlag as Boolean;
    public var windDir as Number?;
    public var windSpeed as Number?;
    public var outsideAirTemp as Number?;
    public var totalAirTemp as Number?;

    public function initialize(dict as Dictionary) {
        var hexVal = dict["hex"];
        hex = hexVal instanceof Lang.String ? hexVal : "";

        var f = dict["flight"];
        flight =
            f instanceof Lang.String ? _validCallsignOrNull(_trim(f)) : null;

        lat = _toFloat(dict["lat"], 0.0);
        lon = _toFloat(dict["lon"], 0.0);

        var ab = dict["alt_baro"];
        if (ab instanceof Lang.String) {
            onGround = true;
            altBaro = 0;
        } else if (JsonUtil.isNumeric(ab)) {
            onGround = false;
            altBaro = ab.toNumber();
        } else {
            onGround = false;
            // No barometric reading at all - fall back to GPS/geometric altitude rather than showing nothing.
            altBaro = JsonUtil.toNumberOrNull(dict["alt_geom"]);
        }

        gs = JsonUtil.toFloatOrNull(dict["gs"]);
        track = JsonUtil.toFloatOrNull(dict["track"]);
        var hdgVal = _floatOr(dict["true_heading"], dict["mag_heading"]);
        heading = hdgVal != null ? hdgVal : track;

        var cat = dict["category"];
        category = cat instanceof Lang.String ? cat : null;

        registration = _toTrimmedStringOrNull(dict["r"]);
        typeCode = _toTrimmedStringOrNull(dict["t"]);
        typeDesc = _toTrimmedStringOrNull(dict["desc"]);

        var flagsNum = JsonUtil.toNumberOrNull(dict["dbFlags"]);
        military = flagsNum != null && (flagsNum & 1) != 0;

        vertRate = _floatOr(dict["baro_rate"], dict["geom_rate"]);

        squawk = _toTrimmedStringOrNull(dict["squawk"]);

        tas = JsonUtil.toFloatOrNull(dict["tas"]);

        emergency = _toTrimmedStringOrNull(dict["emergency"]);

        navAltitude = JsonUtil.toNumberOrNull(dict["nav_altitude_mcp"]);
        if (navAltitude == null) {
            navAltitude = JsonUtil.toNumberOrNull(dict["nav_altitude_fms"]);
        }
        navHeading = JsonUtil.toFloatOrNull(dict["nav_heading"]);

        positionAgeSec = _floatOr(dict["seen_pos"], dict["seen"]);

        var ownOp = _toTrimmedStringOrNull(dict["ownOp"]);
        operatorName =
            ownOp != null ? TextUtil.foldDiacritics(ownOp as String) : null;
        ias = JsonUtil.toNumberOrNull(dict["ias"]);
        mach = JsonUtil.toFloatOrNull(dict["mach"]);
        spi = _toBoolFlag(dict["spi"]);
        alertFlag = _toBoolFlag(dict["alert"]);
        windDir = JsonUtil.toNumberOrNull(dict["wd"]);
        windSpeed = JsonUtil.toNumberOrNull(dict["ws"]);
        outsideAirTemp = JsonUtil.toNumberOrNull(dict["oat"]);
        totalAirTemp = JsonUtil.toNumberOrNull(dict["tat"]);
    }

    // DO-260B set C (C0-C2) is surface emitters, never an airborne class - distinct from a plane that's merely onGround.
    public function isGroundVehicle() as Boolean {
        return (
            category != null &&
            (category.equals("C0") or
                category.equals("C1") or
                category.equals("C2"))
        );
    }

    // DO-260B C3-C5 = point/cluster/line obstacles - towers, masts, tethered balloons.
    public function isObstacle() as Boolean {
        return (
            category != null &&
            (category.equals("C3") or
                category.equals("C4") or
                category.equals("C5"))
        );
    }

    // Checks the API's own emergency field first - not every real emergency squawks exactly 7500/7600/7700.
    public function isEmergency() as Boolean {
        var em = emergency;
        if (em != null && !em.equals("none")) {
            return true;
        }
        var sq = squawk;
        return (
            sq != null &&
            (sq.equals("7500") or sq.equals("7600") or sq.equals("7700"))
        );
    }

    private function _toFloat(v, def as Float) as Float {
        var f = JsonUtil.toFloatOrNull(v);
        return f != null ? f : def;
    }

    private function _toBoolFlag(v) as Boolean {
        if (v instanceof Lang.Boolean) {
            return v as Boolean;
        }
        var n = JsonUtil.toNumberOrNull(v);
        return n != null && n != 0;
    }

    private function _floatOr(primary, fallback) as Float? {
        var f = JsonUtil.toFloatOrNull(primary);
        return f != null ? f : JsonUtil.toFloatOrNull(fallback);
    }

    private function _toTrimmedStringOrNull(v) as String? {
        if (!(v instanceof Lang.String)) {
            return null;
        }
        var s = _trim(v);
        return s.length() > 0 ? s : null;
    }

    // Real Mode S callsigns are A-Z/0-9/space only - anything else is a corrupted decode, not a real name.
    private function _validCallsignOrNull(s as String) as String? {
        if (s.length() == 0) {
            return null;
        }
        var chars = s.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var c = chars[i];
            var isValid =
                (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ';
            if (!isValid) {
                return null;
            }
        }
        return s;
    }

    // adsb.fi pads "flight" to a fixed width with spaces.
    private function _trim(s as String) as String {
        var chars = s.toCharArray();
        var start = 0;
        var end = chars.size() - 1;
        while (start <= end && chars[start] == ' ') {
            start += 1;
        }
        while (end >= start && chars[end] == ' ') {
            end -= 1;
        }
        if (start > end) {
            return "";
        }
        return s.substring(start, end + 1) as String;
    }
}
