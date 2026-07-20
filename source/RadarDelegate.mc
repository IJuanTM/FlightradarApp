import Toybox.Lang;
import Toybox.WatchUi;

// Bottom-right (ESC) is recenter/deselect while there's a pan or selection to clear, otherwise falls
// through to the platform's default back behavior (exits the app), like every other watch-app root view.
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
            return _view.recenter();
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
    // Also suppressed briefly after the full-detail view closes - see RadarView.suppressInputBriefly.
    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();

        if (
            _view.isDragActive() or
            _view.consumeTapSuppression() or
            _view.isInputSuppressed()
        ) {
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

    public function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        if (_view.isInputSuppressed()) {
            return true;
        }
        if (swipeEvent.getDirection() == WatchUi.SWIPE_UP) {
            return _view.trySwipeOpenDetail();
        }
        return false;
    }

    public function onDrag(dragEvent as WatchUi.DragEvent) as Boolean {
        if (_view.isInputSuppressed()) {
            return true;
        }
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
