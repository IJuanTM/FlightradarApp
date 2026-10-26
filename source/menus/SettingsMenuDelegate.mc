import Toybox.Lang;
import Toybox.WatchUi;

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
