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
        new LabelField("altitude", Rez.Strings.LabelAltitude, false),
    ];

    var zoomIndex as Number = 0;
    var labelsEnabled as Boolean = true;
    var _labelFieldEnabled as Dictionary<String, Boolean> = {};
    // Opt-in filters, not opt-out - both default off/shown.
    var hideGroundVehicles as Boolean = false;
    var hideGroundedPlanes as Boolean = false;
    // Opt-out - towers/masts/obstacles default hidden, unlike the other two filters above.
    var hideObstacles as Boolean = true;
    // Display chrome toggles - all opt-out, default shown.
    var showRangeRings as Boolean = true;
    var showGridLines as Boolean = true;
    var showScaleBar as Boolean = true;
    var showButtonHints as Boolean = true;

    function load() as Void {
        var storedZoom = Storage.getValue("zoomIndex");
        zoomIndex = storedZoom != null ? storedZoom as Number : 0;
        if (zoomIndex < 0 or zoomIndex >= ZOOM_LEVELS_KM.size()) {
            zoomIndex = 0;
        }

        labelsEnabled = _loadBool("labelsEnabled", true);
        hideGroundVehicles = _loadBool("hideGroundVehicles", false);
        hideGroundedPlanes = _loadBool("hideGroundedPlanes", false);
        hideObstacles = _loadBool("hideObstacles", true);
        showRangeRings = _loadBool("showRangeRings", true);
        showGridLines = _loadBool("showGridLines", true);
        showScaleBar = _loadBool("showScaleBar", true);
        showButtonHints = _loadBool("showButtonHints", true);

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

    function setHideGroundVehicles(v as Boolean) as Void {
        hideGroundVehicles = v;
        Storage.setValue("hideGroundVehicles", v);
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

    function setShowScaleBar(v as Boolean) as Void {
        showScaleBar = v;
        Storage.setValue("showScaleBar", v);
    }

    function setShowButtonHints(v as Boolean) as Void {
        showButtonHints = v;
        Storage.setValue("showButtonHints", v);
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
