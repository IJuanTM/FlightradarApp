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

    var zoomIndex as Number = 0;
    var labelsEnabled as Boolean = true;
    var _labelFieldEnabled as Dictionary<String, Boolean> = {};
    // Opt-in - ground vehicles hidden by default, unlike hideGroundedPlanes below.
    var showGroundVehicles as Boolean = false;
    var hideGroundedPlanes as Boolean = false;
    // Opt-out - towers/masts/obstacles default hidden, unlike the other two filters above.
    var hideObstacles as Boolean = true;
    // Display chrome toggles - all opt-out, default shown.
    var showRangeRings as Boolean = true;
    var showGridLines as Boolean = true;
    var showButtonHints as Boolean = true;
    // Opt-out - metric is opt-in instead, aviation convention (ft/kt) is the sensible default.
    var useMetricUnits as Boolean = false;
    var batterySaverMode as Boolean = false;

    // Aircraft display toggles - all opt-out, default on (matches existing always-on behavior before these settings existed).
    var showSelectedTrail as Boolean = true;
    var showVertRateChevron as Boolean = true;
    var dimGroundedAircraft as Boolean = true;
    var dimStaleAircraft as Boolean = true;
    var singleColorMode as Boolean = false;
    // Opt-in - military aircraft shown (just tinted) by default, same pattern as showGroundVehicles.
    var hideMilitary as Boolean = false;

    function load() as Void {
        var storedZoom = Storage.getValue("zoomIndex");
        zoomIndex = storedZoom != null ? storedZoom as Number : 0;
        if (zoomIndex < 0 or zoomIndex >= ZOOM_LEVELS_KM.size()) {
            zoomIndex = 0;
        }

        labelsEnabled = _loadBool("labelsEnabled", true);
        showGroundVehicles = _loadBool("showGroundVehicles", false);
        hideGroundedPlanes = _loadBool("hideGroundedPlanes", false);
        hideObstacles = _loadBool("hideObstacles", true);
        showRangeRings = _loadBool("showRangeRings", true);
        showGridLines = _loadBool("showGridLines", true);
        showButtonHints = _loadBool("showButtonHints", true);
        useMetricUnits = _loadBool("useMetricUnits", false);
        batterySaverMode = _loadBool("batterySaverMode", false);
        showSelectedTrail = _loadBool("showSelectedTrail", true);
        showVertRateChevron = _loadBool("showVertRateChevron", true);
        dimGroundedAircraft = _loadBool("dimGroundedAircraft", true);
        dimStaleAircraft = _loadBool("dimStaleAircraft", true);
        singleColorMode = _loadBool("singleColorMode", false);
        hideMilitary = _loadBool("hideMilitary", false);

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

    function setLabelsEnabled(v as Boolean) as Void {
        labelsEnabled = v;
        Storage.setValue("labelsEnabled", v);
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

    function setUseMetricUnits(v as Boolean) as Void {
        useMetricUnits = v;
        Storage.setValue("useMetricUnits", v);
    }

    function setBatterySaverMode(v as Boolean) as Void {
        batterySaverMode = v;
        Storage.setValue("batterySaverMode", v);
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

    function setHideMilitary(v as Boolean) as Void {
        hideMilitary = v;
        Storage.setValue("hideMilitary", v);
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
