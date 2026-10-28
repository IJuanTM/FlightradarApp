import Toybox.Lang;

const APP_VERSION = "0.18.4";
// Movement below this is tap jitter, not a drag - shared by the radar pan and the detail-view scroll.
const DRAG_THRESHOLD_PX = 32;
// SDK docs: Timer's minimum interval defaults to 50ms and depends on the host system.
const MIN_TIMER_INTERVAL_MS = 50;
