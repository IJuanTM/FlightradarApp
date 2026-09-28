import Toybox.Lang;
import Toybox.WatchUi;

// Built programmatically (not from resource XML) since Menu2 toggle items need live Settings values.
module MenuBuilder {
    function buildSubmenu(id as Symbol) as WatchUi.Menu2? {
        if (id == :display) {
            return buildDisplayMenu();
        } else if (id == :radar) {
            return buildRadarMenu();
        } else if (id == :map) {
            return buildMapMenu();
        } else if (id == :airports) {
            return buildAirportsMenu();
        } else if (id == :filters) {
            return buildFiltersMenu();
        } else if (id == :aircraft) {
            return buildAircraftMenu();
        } else if (id == :aircraftOverlays) {
            return buildAircraftOverlaysMenu();
        } else if (id == :aircraftColoring) {
            return buildAircraftColoringMenu();
        } else if (id == :labels) {
            return buildLabelsMenu();
        } else if (id == :labelFields) {
            return buildLabelFieldsMenu();
        } else if (id == :general) {
            return buildGeneralMenu();
        }
        return null;
    }

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

    function buildDisplayMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.DisplayMenuTitle,
        });
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuRadar, null, :radar, null)
        );
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuMap, null, :map, null)
        );
        menu.addItem(
            new WatchUi.MenuItem(
                Rez.Strings.MenuAirports,
                null,
                :airports,
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

    function buildRadarMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.RadarMenuTitle,
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
        return menu;
    }

    function buildMapMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.MapMenuTitle,
        });
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
        return menu;
    }

    function buildAirportsMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.AirportsMenuTitle,
        });
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
                Rez.Strings.MenuShowSmallAirports,
                null,
                :showSmallAirports,
                Settings.showSmallAirports,
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
            new WatchUi.MenuItem(
                Rez.Strings.MenuAircraftOverlays,
                null,
                :aircraftOverlays,
                null
            )
        );
        menu.addItem(
            new WatchUi.MenuItem(
                Rez.Strings.MenuAircraftColoring,
                null,
                :aircraftColoring,
                null
            )
        );
        menu.addItem(
            new WatchUi.MenuItem(Rez.Strings.MenuLabels, null, :labels, null)
        );
        return menu;
    }

    function buildAircraftOverlaysMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.AircraftOverlaysMenuTitle,
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
        return menu;
    }

    function buildAircraftColoringMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.AircraftColoringMenuTitle,
        });
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
                :labelsEnabled,
                Settings.labelsEnabled,
                null
            )
        );
        menu.addItem(
            new WatchUi.MenuItem(
                Rez.Strings.MenuLabelFields,
                null,
                :labelFields,
                null
            )
        );
        return menu;
    }

    function buildLabelFieldsMenu() as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({
            :title => Rez.Strings.LabelFieldsMenuTitle,
        });
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

class SettingsMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (item instanceof WatchUi.ToggleMenuItem) {
            var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();
            if (id instanceof Lang.String) {
                Settings.setLabelFieldEnabled(id, enabled);
            } else {
                Settings.setToggle(id as Symbol, enabled);
            }
            return;
        }

        if (id == :mapStyle) {
            WatchUi.pushView(
                MenuBuilder.buildMapStyleMenu(),
                new MapStyleMenuDelegate(item),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        if (id == :status) {
            WatchUi.pushView(
                MenuBuilder.buildStatusMenu(),
                new WatchUi.Menu2InputDelegate(),
                WatchUi.SLIDE_LEFT
            );
            return;
        }

        var submenu = MenuBuilder.buildSubmenu(id as Symbol);
        if (submenu != null) {
            WatchUi.pushView(
                submenu,
                new SettingsMenuDelegate(),
                WatchUi.SLIDE_LEFT
            );
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
