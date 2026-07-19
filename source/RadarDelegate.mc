import Toybox.Lang;
import Toybox.WatchUi;

// Bottom-right (ESC) is repurposed for recenter instead of back/exit - there's no exit button on the radar screen.
class RadarDelegate extends WatchUi.BehaviorDelegate {
    private var _view as RadarView;

    public function initialize(view as RadarView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();

        if (key == WatchUi.KEY_UP) {
            _view.zoomIn();
            return true;
        } else if (key == WatchUi.KEY_DOWN) {
            _view.zoomOut();
            return true;
        } else if (key == WatchUi.KEY_ESC) {
            _view.recenter();
            return true;
        } else if (key == WatchUi.KEY_ENTER or key == WatchUi.KEY_MENU) {
            WatchUi.pushView(
                MenuBuilder.buildMainMenu(),
                new MainMenuDelegate(),
                WatchUi.SLIDE_UP
            );
            return true;
        }

        return false;
    }

    // Suppressed right after a committed drag and while one is active - a real gesture can leave a stray tap.
    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();

        if (_view.isDragActive() or _view.consumeTapSuppression()) {
            return true;
        }

        if (_view.tryOpenDetailPanel(coords[0], coords[1])) {
            return true;
        }

        var hex = _view.hitTestAircraft(coords[0], coords[1]);
        if (hex != null) {
            _view.selectAircraft(hex as String);
        } else {
            _view.deselectAircraftKeepView();
        }
        return true;
    }

    public function onDrag(dragEvent as WatchUi.DragEvent) as Boolean {
        var coords = dragEvent.getCoordinates();
        var type = dragEvent.getType();

        if (type == WatchUi.DRAG_TYPE_START) {
            _view.beginDrag(coords[0], coords[1]);
        } else if (type == WatchUi.DRAG_TYPE_CONTINUE) {
            _view.continueDrag(coords[0], coords[1]);
        } else if (type == WatchUi.DRAG_TYPE_STOP) {
            _view.endDrag(coords[0], coords[1]);
        }

        return true;
    }
}
