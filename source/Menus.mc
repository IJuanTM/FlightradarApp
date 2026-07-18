import Toybox.Lang;
import Toybox.WatchUi;

// Built programmatically (not from resource XML) since Menu2 toggle items need live Settings values.
module MenuBuilder {
    function buildMainMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.MenuTitle });
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuLabels, null, :labels, null)
        );
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuDisplay, null, :display, null)
        );
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuFilters, null, :filters, null)
        );
        menu.addItem(
            new WatchUi.MenuItem(
                Rez.Strings.MenuAircraft,
                null,
                :aircraft,
                null
            )
        );
        return menu;
    }

    function buildDisplayMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.DisplayMenuTitle });
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuShowRangeRings,
                null,
                :showRangeRings,
                Settings.showRangeRings,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuShowGridLines,
                null,
                :showGridLines,
                Settings.showGridLines,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuShowButtonHints,
                null,
                :showButtonHints,
                Settings.showButtonHints,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuMetricUnits,
                null,
                :useMetricUnits,
                Settings.useMetricUnits,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuBatterySaver,
                null,
                :batterySaverMode,
                Settings.batterySaverMode,
                null
            )
        );
        return menu;
    }

    function buildFiltersMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.FiltersMenuTitle });
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuShowGroundVehicles,
                null,
                :showGroundVehicles,
                Settings.showGroundVehicles,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuHideGroundedPlanes,
                null,
                :hideGroundedPlanes,
                Settings.hideGroundedPlanes,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuHideObstacles,
                null,
                :hideObstacles,
                Settings.hideObstacles,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuHideMilitary,
                null,
                :hideMilitary,
                Settings.hideMilitary,
                null
            )
        );
        return menu;
    }

    function buildAircraftMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.AircraftMenuTitle });
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuShowTrack,
                null,
                :showSelectedTrail,
                Settings.showSelectedTrail,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuShowVertRateChevron,
                null,
                :showVertRateChevron,
                Settings.showVertRateChevron,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuDimGroundedAircraft,
                null,
                :dimGroundedAircraft,
                Settings.dimGroundedAircraft,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuDimStaleAircraft,
                null,
                :dimStaleAircraft,
                Settings.dimStaleAircraft,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuSingleColorMode,
                null,
                :singleColorMode,
                Settings.singleColorMode,
                null
            )
        );
        return menu;
    }

    function buildLabelsMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.LabelsMenuTitle });
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuLabelsSub,
                null,
                :labelsMaster,
                Settings.labelsEnabled,
                null
            )
        );

        var fields = Settings.LABEL_FIELDS;
        for (var i = 0; i < fields.size(); i++) {
            var field = fields[i];
            menu.addItem(
                new WatchUi.ToggleMenuItem(
                    field.stringId,
                    null,
                    field.id,
                    Settings.isLabelFieldEnabled(field.id),
                    null
                )
            );
        }

        return menu;
    }
}

class MainMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (id == :labels) {
            WatchUi.pushView(
                MenuBuilder.buildLabelsMenu(),
                new LabelsMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id == :display) {
            WatchUi.pushView(
                MenuBuilder.buildDisplayMenu(),
                new DisplayMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id == :filters) {
            WatchUi.pushView(
                MenuBuilder.buildFiltersMenu(),
                new FiltersMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id == :aircraft) {
            WatchUi.pushView(
                MenuBuilder.buildAircraftMenu(),
                new AircraftMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }
    }
}

class DisplayMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        if (!(item instanceof WatchUi.ToggleMenuItem)) {
            return;
        }
        var id = item.getId();
        var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();

        if (id == :showRangeRings) {
            Settings.setShowRangeRings(enabled);
        } else if (id == :showGridLines) {
            Settings.setShowGridLines(enabled);
        } else if (id == :showButtonHints) {
            Settings.setShowButtonHints(enabled);
        } else if (id == :useMetricUnits) {
            Settings.setUseMetricUnits(enabled);
        } else if (id == :batterySaverMode) {
            Settings.setBatterySaverMode(enabled);
        }
    }
}

class FiltersMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        if (!(item instanceof WatchUi.ToggleMenuItem)) {
            return;
        }
        var id = item.getId();
        var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();

        if (id == :showGroundVehicles) {
            Settings.setShowGroundVehicles(enabled);
        } else if (id == :hideGroundedPlanes) {
            Settings.setHideGroundedPlanes(enabled);
        } else if (id == :hideObstacles) {
            Settings.setHideObstacles(enabled);
        } else if (id == :hideMilitary) {
            Settings.setHideMilitary(enabled);
        }
    }
}

class AircraftMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        if (!(item instanceof WatchUi.ToggleMenuItem)) {
            return;
        }
        var id = item.getId();
        var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();

        if (id == :showSelectedTrail) {
            Settings.setShowSelectedTrail(enabled);
        } else if (id == :showVertRateChevron) {
            Settings.setShowVertRateChevron(enabled);
        } else if (id == :dimGroundedAircraft) {
            Settings.setDimGroundedAircraft(enabled);
        } else if (id == :dimStaleAircraft) {
            Settings.setDimStaleAircraft(enabled);
        } else if (id == :singleColorMode) {
            Settings.setSingleColorMode(enabled);
        }
    }
}

class LabelsMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        if (!(item instanceof WatchUi.ToggleMenuItem)) {
            return;
        }

        var id = item.getId();
        var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();

        if (id == :labelsMaster) {
            Settings.setLabelsEnabled(enabled);
        } else {
            Settings.setLabelFieldEnabled(id as String, enabled);
        }
    }
}
