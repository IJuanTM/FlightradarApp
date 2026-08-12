import Toybox.Lang;

// Runtime-only last-known state per network source, for the Settings status screen - not persisted,
// not used for any behavior, purely a read-out. Each RadarView result handler reports into this.
module ApiStatus {
    enum {
        NEVER_TRIED,
        OK,
        FAILED,
    }

    var feedState = NEVER_TRIED;
    var feedCode as Number = 0;
    var mapState = NEVER_TRIED;
    var airportsState = NEVER_TRIED;
    var routeState = NEVER_TRIED;
    var airportInfoState = NEVER_TRIED;
    var trackState = NEVER_TRIED;

    function setFeed(ok as Boolean, code as Number) as Void {
        feedState = ok ? OK : FAILED;
        feedCode = code;
    }

    function setMap(ok as Boolean) as Void {
        mapState = ok ? OK : FAILED;
    }

    function setAirports(ok as Boolean) as Void {
        airportsState = ok ? OK : FAILED;
    }

    function setRoute(ok as Boolean) as Void {
        routeState = ok ? OK : FAILED;
    }

    function setAirportInfo(ok as Boolean) as Void {
        airportInfoState = ok ? OK : FAILED;
    }

    function setTrack(ok as Boolean) as Void {
        trackState = ok ? OK : FAILED;
    }

    function label(state) as String {
        if (state == OK) {
            return "OK";
        }
        if (state == FAILED) {
            return "Failed";
        }
        return "Not tried";
    }
}
