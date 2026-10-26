import Toybox.Lang;
import Toybox.WatchUi;

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
