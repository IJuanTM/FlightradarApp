import Toybox.Lang;
import Toybox.WatchUi;

// Built programmatically (not from resource XML) since Menu2 toggle items need live Settings values.
module MenuBuilder {
    function buildMainMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.MenuTitle });
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
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuLabels, null, :labels, null)
        );
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuGeneral, null, :general, null)
        );
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuStatus, null, :status, null)
        );
        menu.addItem(
            new WatchUi.MenuItem("v" + $.APP_VERSION, null, :appVersion, null)
        );
        return menu;
    }

    // Read-only - last-known ok/fail per network source, from ApiStatus. Rebuilt fresh on open, same
    // as every other menu here reading live state; nothing here changes while the menu is showing.
    function buildStatusMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.StatusMenuTitle });
        for (var i = 0; i < ApiStatus.SOURCES.size(); i++) {
            var source = ApiStatus.SOURCES[i];
            var label = ApiStatus.label(source.state);
            if (source == ApiStatus.feed and source.state == ApiStatus.FAILED) {
                label += " (" + ApiStatus.feedCode.toString() + ")";
            }
            menu.addItem(
                new WatchUi.MenuItem(source.stringId, label, :status, null)
            );
        }
        return menu;
    }

    // Screen-chrome toggles (rings/grid/hints/background map), not the aircraft themselves or app-wide behavior.
    function buildDisplayMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.DisplayMenuTitle,
        });
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
                Rez.Strings.MenuShowBackgroundMap,
                null,
                :showBackgroundMap,
                Settings.showBackgroundMap,
                null
            )
        );
        var currentStyle = Settings.mapStyleOption(Settings.mapStyle);
        menu.addItem(
            new WatchUi.MenuItem(
                Rez.Strings.MenuMapStyle,
                currentStyle != null ? currentStyle.stringId : null,
                :mapStyle,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuMapDarkMode,
                null,
                :mapDarkMode,
                Settings.mapDarkMode,
                null
            )
        );
        menu.addItem(
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuShowAirports,
                null,
                :showAirports,
                Settings.showAirports,
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
        return menu;
    }

    function buildMapStyleMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.MapStyleMenuTitle,
        });
        var options = Settings.MAP_STYLE_OPTIONS;
        for (var i = 0; i < options.size(); i++) {
            var opt = options[i];
            menu.addItem(
                new WatchUi.MenuItem(opt.stringId, null, opt.id, null)
            );
        }
        return menu;
    }

    function buildFiltersMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.FiltersMenuTitle,
        });
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
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.AircraftMenuTitle,
        });
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

    // App-wide behavior, not tied to any one visual layer.
    function buildGeneralMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.GeneralMenuTitle,
        });
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
}

class MainMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

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

        if (id == :labels) {
            WatchUi.pushView(
                MenuBuilder.buildLabelsMenu(),
                new LabelsMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id == :general) {
            WatchUi.pushView(
                MenuBuilder.buildGeneralMenu(),
                new GeneralMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id == :status) {
            WatchUi.pushView(
                MenuBuilder.buildStatusMenu(),
                new StatusMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }
    }
}

// Read-only - every row is informational, selecting one does nothing.
class StatusMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {}
}

class DisplayMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (id == :mapStyle) {
            WatchUi.pushView(
                MenuBuilder.buildMapStyleMenu(),
                new MapStyleMenuDelegate(item),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (!(item instanceof WatchUi.ToggleMenuItem)) {
            return;
        }
        var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();

        if (id == :showRangeRings) {
            Settings.setShowRangeRings(enabled);
        } else if (id == :showGridLines) {
            Settings.setShowGridLines(enabled);
        } else if (id == :showButtonHints) {
            Settings.setShowButtonHints(enabled);
        } else if (id == :showBackgroundMap) {
            Settings.setShowBackgroundMap(enabled);
        } else if (id == :mapDarkMode) {
            Settings.setMapDarkMode(enabled);
        } else if (id == :showAirports) {
            Settings.setShowAirports(enabled);
        }
    }
}

// Pops back to the parent item so its subLabel reflects the newly-picked style immediately.
class MapStyleMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _parentItem as WatchUi.MenuItem;

    public function initialize(parentItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        _parentItem = parentItem;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId() as String;
        Settings.setMapStyle(id);
        var opt = Settings.mapStyleOption(id);
        if (opt != null) {
            _parentItem.setSubLabel(opt.stringId);
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
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

class GeneralMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        if (!(item instanceof WatchUi.ToggleMenuItem)) {
            return;
        }
        var id = item.getId();
        var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();

        if (id == :useMetricUnits) {
            Settings.setUseMetricUnits(enabled);
        } else if (id == :batterySaverMode) {
            Settings.setBatterySaverMode(enabled);
        }
    }
}
