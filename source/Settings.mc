import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

module Settings {
    // 100km removed again - the platform's own networking layer still rejects big enough responses.
    const ZOOM_LEVELS_KM as Array<Float> = [5.0, 10.0, 25.0, 50.0];

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

    // id is the literal MapTiler style-id path segment - see MapClient for how it becomes a tile URL.
    // Alphabetical by display name - no other grouping is more obviously "correct" for a named picker.
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

    // Map chrome toggles.
    var showRangeRings as Boolean = true;
    var showGridLines as Boolean = false;
    var showButtonHints as Boolean = true;
    // Opt-in - a background map is the biggest network/battery cost in the app, default off.
    var showBackgroundMap as Boolean = false;
    // MapTiler style id (see MAP_STYLE_OPTIONS) and whether to request its "-dark" variant.
    var mapStyle as String = "base";
    var mapDarkMode as Boolean = true;
    // Opt-in - a second network source (nearby-airport lookups), same rationale as showBackgroundMap.
    var showAirports as Boolean = false;

    // Filters - what traffic appears at all.
    // Opt-in - ground vehicles hidden by default, unlike hideGroundedPlanes below.
    var showGroundVehicles as Boolean = false;
    var hideGroundedPlanes as Boolean = false;
    // Opt-out - towers/masts/obstacles default hidden, unlike the other two filters above.
    var hideObstacles as Boolean = true;
    // Opt-in - military aircraft shown (just tinted) by default, same pattern as showGroundVehicles.
    var hideMilitary as Boolean = false;

    // Aircraft display toggles - all opt-out, default on.
    var showSelectedTrail as Boolean = true;
    var showVertRateChevron as Boolean = true;
    var dimGroundedAircraft as Boolean = true;
    var dimStaleAircraft as Boolean = true;
    var singleColorMode as Boolean = false;

    // Aircraft label fields.
    var labelsEnabled as Boolean = true;
    var _labelFieldEnabled as Dictionary<String, Boolean> = {};

    // General/app-wide behavior.
    // Opt-out - metric is opt-in instead, aviation convention (ft/kt) is the sensible default.
    var useMetricUnits as Boolean = false;
    var batterySaverMode as Boolean = false;

    function load() as Void {
        var storedZoom = Storage.getValue("zoomIndex");
        zoomIndex = storedZoom != null ? storedZoom as Number : 0;
        if (zoomIndex < 0 or zoomIndex >= ZOOM_LEVELS_KM.size()) {
            zoomIndex = 0;
        }

        showRangeRings = _loadBool("showRangeRings", true);
        showGridLines = _loadBool("showGridLines", false);
        showButtonHints = _loadBool("showButtonHints", true);
        showBackgroundMap = _loadBool("showBackgroundMap", false);
        mapStyle = _loadString("mapStyle", "base");
        mapDarkMode = _loadBool("mapDarkMode", true);
        showAirports = _loadBool("showAirports", false);

        showGroundVehicles = _loadBool("showGroundVehicles", false);
        hideGroundedPlanes = _loadBool("hideGroundedPlanes", false);
        hideObstacles = _loadBool("hideObstacles", true);
        hideMilitary = _loadBool("hideMilitary", false);

        showSelectedTrail = _loadBool("showSelectedTrail", true);
        showVertRateChevron = _loadBool("showVertRateChevron", true);
        dimGroundedAircraft = _loadBool("dimGroundedAircraft", true);
        dimStaleAircraft = _loadBool("dimStaleAircraft", true);
        singleColorMode = _loadBool("singleColorMode", false);

        labelsEnabled = _loadBool("labelsEnabled", true);

        useMetricUnits = _loadBool("useMetricUnits", false);
        batterySaverMode = _loadBool("batterySaverMode", false);

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

    function _loadString(key as String, defaultVal as String) as String {
        var v = Storage.getValue(key);
        return v == null ? defaultVal : v as String;
    }

    function zoomRadiusKm() as Float {
        return ZOOM_LEVELS_KM[zoomIndex];
    }

    function zoomIn() as Void {
        if (zoomIndex > 0) {
            zoomIndex -= 1;
            Storage.setValue("zoomIndex", zoomIndex);
        }
    }

    function zoomOut() as Void {
        if (zoomIndex < ZOOM_LEVELS_KM.size() - 1) {
            zoomIndex += 1;
            Storage.setValue("zoomIndex", zoomIndex);
        }
    }

    function setShowRangeRings(v as Boolean) as Void {
        showRangeRings = v;
        Storage.setValue("showRangeRings", v);
    }

    function setShowGridLines(v as Boolean) as Void {
        showGridLines = v;
        Storage.setValue("showGridLines", v);
    }

    function setShowButtonHints(v as Boolean) as Void {
        showButtonHints = v;
        Storage.setValue("showButtonHints", v);
    }

    function setShowBackgroundMap(v as Boolean) as Void {
        showBackgroundMap = v;
        Storage.setValue("showBackgroundMap", v);
    }

    function setMapStyle(v as String) as Void {
        mapStyle = v;
        Storage.setValue("mapStyle", v);
    }

    function setMapDarkMode(v as Boolean) as Void {
        mapDarkMode = v;
        Storage.setValue("mapDarkMode", v);
    }

    function setShowAirports(v as Boolean) as Void {
        showAirports = v;
        Storage.setValue("showAirports", v);
    }

    function setShowGroundVehicles(v as Boolean) as Void {
        showGroundVehicles = v;
        Storage.setValue("showGroundVehicles", v);
    }

    function setHideGroundedPlanes(v as Boolean) as Void {
        hideGroundedPlanes = v;
        Storage.setValue("hideGroundedPlanes", v);
    }

    function setHideObstacles(v as Boolean) as Void {
        hideObstacles = v;
        Storage.setValue("hideObstacles", v);
    }

    function setHideMilitary(v as Boolean) as Void {
        hideMilitary = v;
        Storage.setValue("hideMilitary", v);
    }

    function setShowSelectedTrail(v as Boolean) as Void {
        showSelectedTrail = v;
        Storage.setValue("showSelectedTrail", v);
    }

    function setShowVertRateChevron(v as Boolean) as Void {
        showVertRateChevron = v;
        Storage.setValue("showVertRateChevron", v);
    }

    function setDimGroundedAircraft(v as Boolean) as Void {
        dimGroundedAircraft = v;
        Storage.setValue("dimGroundedAircraft", v);
    }

    function setDimStaleAircraft(v as Boolean) as Void {
        dimStaleAircraft = v;
        Storage.setValue("dimStaleAircraft", v);
    }

    function setSingleColorMode(v as Boolean) as Void {
        singleColorMode = v;
        Storage.setValue("singleColorMode", v);
    }

    function setLabelsEnabled(v as Boolean) as Void {
        labelsEnabled = v;
        Storage.setValue("labelsEnabled", v);
    }

    function setUseMetricUnits(v as Boolean) as Void {
        useMetricUnits = v;
        Storage.setValue("useMetricUnits", v);
    }

    function setBatterySaverMode(v as Boolean) as Void {
        batterySaverMode = v;
        Storage.setValue("batterySaverMode", v);
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
