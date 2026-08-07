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

    // enableLocationEvents defaults to GPS-only positioning unless :configuration is set explicitly.
    public function onStart(state as Dictionary?) as Void {
        var options = { :acquisitionType => Position.LOCATION_CONTINUOUS };
        if (Position has :hasConfigurationSupport) {
            if (
                Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5 &&
                Position.hasConfigurationSupport(
                    Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5
                )
            ) {
                options[:configuration] =
                    Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5;
            } else if (
                Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1 &&
                Position.hasConfigurationSupport(
                    Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1
                )
            ) {
                options[:configuration] =
                    Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1;
            }
        }
        Position.enableLocationEvents(options, method(:onPosition));
    }

    public function onStop(state as Dictionary?) as Void {
        Position.enableLocationEvents(
            Position.LOCATION_DISABLE,
            method(:onPosition)
        );
        _radarView.persistLastKnownPosition();
    }

    public function onPosition(info as Position.Info) as Void {
        _radarView.onPosition(info);
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        return [_radarView, new RadarDelegate(_radarView)];
    }
}
