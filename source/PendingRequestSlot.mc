import Toybox.Lang;

// Shared by AirplanesLiveClient/OpenSkyClient - each wants only one physical request in flight, and no :context/generation id exists to correlate a second one safely.
// Payload/callback are untyped (Object?/Method?, not generic - Monkey C has no generic classes); each caller casts back to its own shape, documented at its own _slot field.
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

    // True return means dispatch now; false means it was queued behind an already-active request.
    // A third call while one is already queued overwrites the queued slot (depth 1, not a real
    // queue) - safe only because both callers always pass the same bound callback, so the newest
    // payload is simply the freshest desired request, never a caller left permanently unanswered.
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

    // True return means a queued request was promoted into active and should be dispatched now.
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
