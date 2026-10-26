import Toybox.Lang;
import Toybox.WatchUi;

class AircraftDetailDelegate extends WatchUi.BehaviorDelegate {
    private var _view as AircraftDetailView;
    private var _dragStartY as Number?;
    private var _dragLastY as Number?;
    private var _dragCommitted as Boolean = false;
    private const SCROLL_STEP_PX = 40;

    public function initialize(view as AircraftDetailView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();
        if (key == WatchUi.KEY_UP) {
            _view.scroll(-SCROLL_STEP_PX);
            return true;
        } else if (key == WatchUi.KEY_DOWN) {
            _view.scroll(SCROLL_STEP_PX);
            return true;
        } else if (key == WatchUi.KEY_ESC) {
            _close();
            return true;
        }
        return false;
    }

    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        if (_view.isInputSuppressed()) {
            return true;
        }
        if (_view.isCloseBandHit(clickEvent.getCoordinates()[1])) {
            _close();
            return true;
        }
        return false;
    }

    public function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        if (_view.isInputSuppressed()) {
            return true;
        }
        if (swipeEvent.getDirection() == WatchUi.SWIPE_DOWN) {
            _close();
            return true;
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
            _dragStartY = coords[1];
            _dragLastY = coords[1];
            _dragCommitted = false;
        } else if (type == WatchUi.DRAG_TYPE_CONTINUE) {
            var start = _dragStartY;
            var last = _dragLastY;
            if (start == null or last == null) {
                return true;
            }
            if (!_dragCommitted) {
                if (
                    (coords[1] - (start as Number)).abs() < $.DRAG_THRESHOLD_PX
                ) {
                    _dragLastY = coords[1];
                    return true;
                }
                _dragCommitted = true;
            }
            _view.scroll((last as Number) - coords[1]);
            _dragLastY = coords[1];
        } else if (type == WatchUi.DRAG_TYPE_STOP) {
            _dragStartY = null;
            _dragLastY = null;
            _dragCommitted = false;
        }
        return true;
    }

    private function _close() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
