import Toybox.Lang;

// Runtime-only read-out for the status menu - not persisted, and nothing behaves differently based on it.
module ApiStatus {
    enum {
        NEVER_TRIED,
        OK,
        FAILED,
    }

    class Source {
        public var stringId as ResourceId;
        public var state = NEVER_TRIED;

        public function initialize(stringId as ResourceId) {
            self.stringId = stringId;
        }
    }

    var feed = new Source(Rez.Strings.StatusFeed);
    var map = new Source(Rez.Strings.StatusMap);
    var airports = new Source(Rez.Strings.StatusAirports);
    var route = new Source(Rez.Strings.StatusRoute);
    var airportInfo = new Source(Rez.Strings.StatusAirportInfo);
    var track = new Source(Rez.Strings.StatusTrack);

    // Adding a source here is all the status menu needs.
    var SOURCES as Array<Source> = [
        feed,
        map,
        airports,
        route,
        airportInfo,
        track,
    ];

    // Only the feed currently has a meaningful failure code to show - add more here if that changes.
    var feedCode as Number = 0;

    function setState(source as Source, ok as Boolean) as Void {
        source.state = ok ? OK : FAILED;
    }

    function setFeed(ok as Boolean, code as Number) as Void {
        feedCode = code;
        setState(feed, ok);
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
