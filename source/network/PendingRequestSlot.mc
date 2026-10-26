import Toybox.Lang;

// One request in flight per client keeps late responses unambiguous; payload/callback are untyped since Monkey C has no generics.
class PendingRequestSlot {
    private var _activePayload as Object?;
    private var _activeCallback as Method?;
    private var _queuedPayload as Object?;
    private var _queuedCallback as Method?;

    public function initialize() {}

    public function activePayload() as Object? {
        return _activePayload;
    }

    public function activeCallback() as Method? {
        return _activeCallback;
    }

    // False means queued, depth 1 - a newer call overwrites it, safe since each caller always passes the same bound callback.
    public function start(payload as Object, callback as Method) as Boolean {
        if (_activeCallback != null) {
            _queuedPayload = payload;
            _queuedCallback = callback;
            return false;
        }
        _activePayload = payload;
        _activeCallback = callback;
        return true;
    }

    // Callers must read the active callback before this, or a response gets delivered to the promoted request; true means dispatch now.
    public function clearAndPromote() as Boolean {
        _activePayload = null;
        _activeCallback = null;
        var queuedCallback = _queuedCallback;
        if (queuedCallback == null) {
            return false;
        }
        _activePayload = _queuedPayload;
        _activeCallback = queuedCallback;
        _queuedPayload = null;
        _queuedCallback = null;
        return true;
    }
}
