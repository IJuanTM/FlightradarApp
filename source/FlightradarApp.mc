import Toybox.Application;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.WatchUi;

class FlightradarApp extends Application.AppBase {
    private var _radarView as RadarView;

    public function initialize() {
        AppBase.initialize();
        Settings.load();
        _radarView = new RadarView();
    }

    // Only AppBase gets this, not View - relayed to RadarView, which owns the poll timer.
    public function onDisplayModeChanged() as Void {
        _radarView.onDisplayModeChanged(System.getDisplayMode());
    }

    public function onStart(state as Dictionary?) as Void {
        Position.enableLocationEvents(
            Position.LOCATION_CONTINUOUS,
            method(:onPosition)
        );
    }

    public function onStop(state as Dictionary?) as Void {
        Position.enableLocationEvents(
            Position.LOCATION_DISABLE,
            method(:onPosition)
        );
    }

    public function onPosition(info as Position.Info) as Void {
        _radarView.onPosition(info);
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        return [_radarView, new RadarDelegate(_radarView)];
    }
}
