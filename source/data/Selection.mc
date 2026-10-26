import Toybox.Lang;

class Selection {
    private const MAX_MISSES = 3;
    // Only bounds ongoing growth, never the initial OpenSky history.
    private const MAX_TRACK_POINTS = 500;

    public var hex as String?;
    // Null while the selected hex is missing from the latest poll.
    public var aircraft as Aircraft?;
    // Last confirmed position - frozen-camera fallback on auto-deselect, see RadarView._onFeedResult.
    public var lastPos as [Float, Float]?;
    // [lat, lon, altitudeFt, onGround] - onGround drives the trail's dashed rendering.
    public var track as Array<[Float, Float, Number, Boolean]> = [];
    public var trackHasHistory as Boolean = false;
    private var _missCount as Number = 0;

    public function initialize() {}

    public function select(newHex as String, ac as Aircraft?) as Void {
        hex = newHex;
        aircraft = ac;
        track = [];
        trackHasHistory = false;
        _missCount = 0;
        lastPos = ac != null ? [ac.lat, ac.lon] : null;
    }

    public function clear() as Void {
        hex = null;
        aircraft = null;
        track = [];
        _missCount = 0;
        lastPos = null;
    }

    // Guards against a response landing after the selection changed mid-fetch.
    public function isSelected(fetchedHex as String?) as Boolean {
        return (
            fetchedHex != null &&
            hex != null &&
            (fetchedHex as String).equals(hex as String)
        );
    }

    // True once the selected aircraft has been missing from MAX_MISSES polls in a row.
    public function refresh(byHex as Dictionary<String, Aircraft>) as Boolean {
        var selectedHex = hex;
        if (selectedHex == null) {
            return false;
        }
        var ac = byHex[selectedHex];
        aircraft = ac;
        if (ac == null) {
            _missCount += 1;
            return _missCount >= MAX_MISSES;
        }
        _missCount = 0;
        lastPos = [ac.lat, ac.lon];
        appendLivePoint(ac);
        return false;
    }

    public function appendLivePoint(ac as Aircraft) as Void {
        track.add([
            ac.lat,
            ac.lon,
            ac.altBaro != null ? ac.altBaro as Number : 0,
            ac.onGround,
        ]);
        if (track.size() > MAX_TRACK_POINTS) {
            track = track.slice(track.size() - MAX_TRACK_POINTS, null);
        }
    }
}
