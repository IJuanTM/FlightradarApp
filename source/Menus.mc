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
            new WatchUi.ToggleMenuItem(
                Rez.Strings.MenuHideGroundVehicles,
                null,
                :hideGroundVehicles,
                Settings.hideGroundVehicles,
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
                Rez.Strings.MenuShowScaleBar,
                null,
                :showScaleBar,
                Settings.showScaleBar,
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

        if (!(item instanceof WatchUi.ToggleMenuItem)) {
            return;
        }
        var enabled = (item as WatchUi.ToggleMenuItem).isEnabled();
        if (id == :hideGroundVehicles) {
            Settings.setHideGroundVehicles(enabled);
        } else if (id == :hideGroundedPlanes) {
            Settings.setHideGroundedPlanes(enabled);
        } else if (id == :hideObstacles) {
            Settings.setHideObstacles(enabled);
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
        } else if (id == :showScaleBar) {
            Settings.setShowScaleBar(enabled);
        } else if (id == :showButtonHints) {
            Settings.setShowButtonHints(enabled);
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
