import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

module Settings {
    // [radiusKm, pollMs, gridStepKm] - polls slow down at wide zoom, where responses near the platform's size ceiling.
    const ZOOM_LEVELS as Array<[Float, Number, Float]> = [
        [5.0, 1000, 1.0],
        [10.0, 1000, 5.0],
        [25.0, 2000, 10.0],
        [50.0, 3000, 25.0],
    ];

    class LabelField {
        public var id as String;
        public var stringId as ResourceId;
        public var defaultOn as Boolean;

        public function initialize(
            id as String,
            stringId as ResourceId,
            defaultOn as Boolean
        ) {
            self.id = id;
            self.stringId = stringId;
            self.defaultOn = defaultOn;
        }
    }

    var LABEL_FIELDS as Array<LabelField> = [
        new LabelField("callsign", Rez.Strings.LabelCallsign, true),
        new LabelField("speed", Rez.Strings.LabelSpeed, true),
        new LabelField("altitude", Rez.Strings.LabelAltitude, true),
    ];

    class MapStyleOption {
        public var id as String;
        public var stringId as ResourceId;
        // Version segment before "[-dark]" - "-v4" for most styles, "" for unversioned ones.
        public var urlSuffix as String;

        public function initialize(
            id as String,
            stringId as ResourceId,
            urlSuffix as String
        ) {
            self.id = id;
            self.stringId = stringId;
            self.urlSuffix = urlSuffix;
        }
    }

    // id is the literal MapTiler style-id path segment; listed alphabetically by display name.
    var MAP_STYLE_OPTIONS as Array<MapStyleOption> = [
        new MapStyleOption("backdrop", Rez.Strings.MapStyleBackdrop, "-v4"),
        new MapStyleOption("base", Rez.Strings.MapStyleBase, "-v4"),
        new MapStyleOption("dataviz", Rez.Strings.MapStyleDataviz, "-v4"),
        new MapStyleOption("hybrid", Rez.Strings.MapStyleHybrid, "-v4"),
        new MapStyleOption("landscape", Rez.Strings.MapStyleLandscape, "-v4"),
        new MapStyleOption(
            "openstreetmap",
            Rez.Strings.MapStyleOpenStreetMap,
            ""
        ),
        new MapStyleOption("outdoor", Rez.Strings.MapStyleOutdoor, "-v4"),
        new MapStyleOption("satellite", Rez.Strings.MapStyleSatellite, "-v4"),
        new MapStyleOption("streets", Rez.Strings.MapStyleStreets, "-v4"),
        new MapStyleOption("topo", Rez.Strings.MapStyleTopo, "-v4"),
    ];

    function mapStyleOption(id as String) as MapStyleOption? {
        for (var i = 0; i < MAP_STYLE_OPTIONS.size(); i++) {
            if (MAP_STYLE_OPTIONS[i].id.equals(id)) {
                return MAP_STYLE_OPTIONS[i];
            }
        }
        return null;
    }

    var zoomIndex as Number = 0;

    var showRangeRings as Boolean = true;
    var showGridLines as Boolean = false;
    var showButtonHints as Boolean = true;

    // Opt-in - a background map is the biggest network/battery cost in the app, default off.
    var showBackgroundMap as Boolean = false;
    var mapStyle as String = "dataviz";
    var mapDarkMode as Boolean = true;

    var showAirports as Boolean = true;
    // Non-IATA airstrips are most of what OpenAIP returns - the first thing to hide when the view gets cluttered.
    var showSmallAirports as Boolean = true;

    var showGroundVehicles as Boolean = false;
    var hideGroundedPlanes as Boolean = false;
    var hideObstacles as Boolean = true;
    var hideMilitary as Boolean = false;

    var showSelectedTrail as Boolean = true;
    var showVertRateChevron as Boolean = true;

    var dimGroundedAircraft as Boolean = true;
    var dimStaleAircraft as Boolean = true;
    var singleColorMode as Boolean = false;

    var labelsEnabled as Boolean = true;
    var _labelFieldEnabled as Dictionary<String, Boolean> = {};

    var useMetricUnits as Boolean = false;
    var batterySaverMode as Boolean = false;

    // Each field's initializer is its default - load() only overrides it with a stored value.
    function load() as Void {
        var storedZoom = Storage.getValue("zoomIndex");
        if (
            storedZoom instanceof Lang.Number and
            storedZoom >= 0 and
            storedZoom < ZOOM_LEVELS.size()
        ) {
            zoomIndex = storedZoom;
        }

        showRangeRings = _loadBool("showRangeRings", showRangeRings);
        showGridLines = _loadBool("showGridLines", showGridLines);
        showButtonHints = _loadBool("showButtonHints", showButtonHints);

        showBackgroundMap = _loadBool("showBackgroundMap", showBackgroundMap);
        var storedStyle = Storage.getValue("mapStyle");
        // A style later dropped from the picker would otherwise build a tile URL MapTiler doesn't serve.
        if (
            storedStyle instanceof Lang.String and
            mapStyleOption(storedStyle) != null
        ) {
            mapStyle = storedStyle;
        }
        mapDarkMode = _loadBool("mapDarkMode", mapDarkMode);
        showAirports = _loadBool("showAirports", showAirports);
        showSmallAirports = _loadBool("showSmallAirports", showSmallAirports);

        showGroundVehicles = _loadBool(
            "showGroundVehicles",
            showGroundVehicles
        );
        hideGroundedPlanes = _loadBool(
            "hideGroundedPlanes",
            hideGroundedPlanes
        );
        hideObstacles = _loadBool("hideObstacles", hideObstacles);
        hideMilitary = _loadBool("hideMilitary", hideMilitary);

        showSelectedTrail = _loadBool("showSelectedTrail", showSelectedTrail);
        showVertRateChevron = _loadBool(
            "showVertRateChevron",
            showVertRateChevron
        );

        dimGroundedAircraft = _loadBool(
            "dimGroundedAircraft",
            dimGroundedAircraft
        );
        dimStaleAircraft = _loadBool("dimStaleAircraft", dimStaleAircraft);
        singleColorMode = _loadBool("singleColorMode", singleColorMode);

        labelsEnabled = _loadBool("labelsEnabled", labelsEnabled);

        useMetricUnits = _loadBool("useMetricUnits", useMetricUnits);
        batterySaverMode = _loadBool("batterySaverMode", batterySaverMode);

        for (var i = 0; i < LABEL_FIELDS.size(); i++) {
            var field = LABEL_FIELDS[i];
            _labelFieldEnabled[field.id] = _loadBool(
                "label_" + field.id,
                field.defaultOn
            );
        }
    }

    function _loadBool(key as String, defaultVal as Boolean) as Boolean {
        var v = Storage.getValue(key);
        return v == null ? defaultVal : v as Boolean;
    }

    function zoomRadiusKm() as Float {
        return ZOOM_LEVELS[zoomIndex][0];
    }

    function zoomPollMs() as Number {
        return ZOOM_LEVELS[zoomIndex][1];
    }

    function zoomGridStepKm() as Float {
        return ZOOM_LEVELS[zoomIndex][2];
    }

    function zoomIn() as Void {
        if (zoomIndex > 0) {
            zoomIndex -= 1;
            Storage.setValue("zoomIndex", zoomIndex);
        }
    }

    function zoomOut() as Void {
        if (zoomIndex < ZOOM_LEVELS.size() - 1) {
            zoomIndex += 1;
            Storage.setValue("zoomIndex", zoomIndex);
        }
    }

    // id is the menu item id, which is also the setting's own name.
    function setToggle(id as Symbol, v as Boolean) as Void {
        var key;
        if (id == :showRangeRings) {
            showRangeRings = v;
            key = "showRangeRings";
        } else if (id == :showGridLines) {
            showGridLines = v;
            key = "showGridLines";
        } else if (id == :showButtonHints) {
            showButtonHints = v;
            key = "showButtonHints";
        } else if (id == :showBackgroundMap) {
            showBackgroundMap = v;
            key = "showBackgroundMap";
        } else if (id == :mapDarkMode) {
            mapDarkMode = v;
            key = "mapDarkMode";
        } else if (id == :showAirports) {
            showAirports = v;
            key = "showAirports";
        } else if (id == :showSmallAirports) {
            showSmallAirports = v;
            key = "showSmallAirports";
        } else if (id == :showGroundVehicles) {
            showGroundVehicles = v;
            key = "showGroundVehicles";
        } else if (id == :hideGroundedPlanes) {
            hideGroundedPlanes = v;
            key = "hideGroundedPlanes";
        } else if (id == :hideObstacles) {
            hideObstacles = v;
            key = "hideObstacles";
        } else if (id == :hideMilitary) {
            hideMilitary = v;
            key = "hideMilitary";
        } else if (id == :showSelectedTrail) {
            showSelectedTrail = v;
            key = "showSelectedTrail";
        } else if (id == :showVertRateChevron) {
            showVertRateChevron = v;
            key = "showVertRateChevron";
        } else if (id == :dimGroundedAircraft) {
            dimGroundedAircraft = v;
            key = "dimGroundedAircraft";
        } else if (id == :dimStaleAircraft) {
            dimStaleAircraft = v;
            key = "dimStaleAircraft";
        } else if (id == :singleColorMode) {
            singleColorMode = v;
            key = "singleColorMode";
        } else if (id == :labelsEnabled) {
            labelsEnabled = v;
            key = "labelsEnabled";
        } else if (id == :useMetricUnits) {
            useMetricUnits = v;
            key = "useMetricUnits";
        } else if (id == :batterySaverMode) {
            batterySaverMode = v;
            key = "batterySaverMode";
        } else {
            return;
        }
        Storage.setValue(key, v);
    }

    function setMapStyle(v as String) as Void {
        mapStyle = v;
        Storage.setValue("mapStyle", v);
    }

    function isLabelFieldEnabled(id as String) as Boolean {
        var v = _labelFieldEnabled[id];
        return v == null ? false : v;
    }

    function setLabelFieldEnabled(id as String, v as Boolean) as Void {
        _labelFieldEnabled[id] = v;
        Storage.setValue("label_" + id, v);
    }
}
