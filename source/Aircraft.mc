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
        hex = hexVal instanceof String ? hexVal : "";

        var f = dict["flight"];
        flight = f instanceof String ? _validCallsignOrNull(_trim(f)) : null;

        lat = _toFloat(dict["lat"], 0.0);
        lon = _toFloat(dict["lon"], 0.0);

        var ab = dict["alt_baro"];
        if (ab instanceof String) {
            onGround = true;
            altBaro = 0;
        } else if (ab != null) {
            onGround = false;
            altBaro = ab.toNumber();
        } else {
            onGround = false;
            // No barometric reading at all (not even "ground") - fall back to GPS/geometric altitude rather than showing nothing.
            var ag = dict["alt_geom"];
            altBaro = ag != null ? ag.toNumber() : null;
        }

        gs = _toFloatOrNull(dict["gs"]);
        track = _toFloatOrNull(dict["track"]);

        var cat = dict["category"];
        category = cat instanceof String ? cat : null;

        registration = _toTrimmedStringOrNull(dict["r"]);
        typeCode = _toTrimmedStringOrNull(dict["t"]);
        typeDesc = _toTrimmedStringOrNull(dict["desc"]);

        var flags = dict["dbFlags"];
        military = flags != null && (flags.toNumber() & 1) != 0;

        var vr = dict["baro_rate"];
        vertRate = _toFloatOrNull(vr != null ? vr : dict["geom_rate"]);

        squawk = _toTrimmedStringOrNull(dict["squawk"]);

        tas = _toFloatOrNull(dict["tas"]);

        emergency = _toTrimmedStringOrNull(dict["emergency"]);

        var mcp = dict["nav_altitude_mcp"];
        var navAlt = mcp != null ? mcp : dict["nav_altitude_fms"];
        navAltitude = navAlt != null ? navAlt.toNumber() : null;
        navHeading = _toFloatOrNull(dict["nav_heading"]);

        var seenPos = dict["seen_pos"];
        positionAgeSec = _toFloatOrNull(seenPos != null ? seenPos : dict["seen"]);

        operatorName = _toTrimmedStringOrNull(dict["ownOp"]);
        var iasVal = dict["ias"];
        ias = iasVal != null ? iasVal.toNumber() : null;
        mach = _toFloatOrNull(dict["mach"]);
        spi = _toBoolFlag(dict["spi"]);
        alertFlag = _toBoolFlag(dict["alert"]);
        var wdVal = dict["wd"];
        windDir = wdVal != null ? wdVal.toNumber() : null;
        var wsVal = dict["ws"];
        windSpeed = wsVal != null ? wsVal.toNumber() : null;
        var oatVal = dict["oat"];
        outsideAirTemp = oatVal != null ? oatVal.toNumber() : null;
        var tatVal = dict["tat"];
        totalAirTemp = tatVal != null ? tatVal.toNumber() : null;
    }

    public function isHelicopter() as Boolean {
        return category != null && category.equals("A7");
    }

    // DO-260B C1/C2 = surface vehicles, never an airborne class, distinct from a plane that's merely onGround.
    public function isGroundVehicle() as Boolean {
        return category != null &&
            (category.equals("C0") or category.equals("C1") or category.equals("C2"));
    }

    // DO-260B C3-C5 = point/cluster/line obstacles - towers, masts, tethered balloons.
    public function isObstacle() as Boolean {
        return category != null &&
            (category.equals("C3") or category.equals("C4") or category.equals("C5"));
    }

    // Checks the API's own emergency field first - not every real emergency squawks exactly 7500/7600/7700.
    public function isEmergency() as Boolean {
        var em = emergency;
        if (em != null && !em.equals("none")) {
            return true;
        }
        var sq = squawk;
        return sq != null &&
            (sq.equals("7500") or sq.equals("7600") or sq.equals("7700"));
    }

    private function _toFloat(v, def as Float) as Float {
        return v != null ? v.toFloat() : def;
    }

    private function _toBoolFlag(v) as Boolean {
        return v != null && v.toNumber() != 0;
    }

    private function _toFloatOrNull(v) as Float? {
        return v != null ? v.toFloat() : null;
    }

    private function _toTrimmedStringOrNull(v) as String? {
        if (!(v instanceof String)) {
            return null;
        }
        var s = _trim(v);
        return s.length() > 0 ? s : null;
    }

    // Real Mode S callsigns are A-Z/0-9/space only - anything else is a corrupted decode (seen as garbled/non-Latin-looking text), not a real name.
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

    // airplanes.live pads "flight" to a fixed width with spaces.
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
