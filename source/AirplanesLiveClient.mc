import Toybox.Communications;
import Toybox.Lang;
import Toybox.StringUtil;
import Toybox.System;
import Toybox.Timer;

// Thrown when the parser exceeds its time budget, so a slow parse fails gracefully instead of crashing.
class JsonParseAbortedException extends Lang.Exception {
    function initialize() {
        Exception.initialize();
    }
}

// A class (not a module) because Communications.makeWebRequest's callback needs a bound method(:symbol).
class AirplanesLiveClient {
    private const BASE_URL = "https://api.airplanes.live/v2/point";

    // tooMuchData distinguishes the known response-size-ceiling failure (-400/-402/-403) from a generic failure.
    typedef FetchCallback as
        (Method
            (
                aircraft as Array<Aircraft>,
                ok as Boolean,
                tooMuchData as Boolean
            ) as Void
        );

    // airplanes.live documents a 1 req/sec limit - a bit of margin above that.
    private const MIN_REQUEST_INTERVAL_MS = 1100;

    // SDK docs: Timer's minimum interval defaults to 50ms and depends on the host system.
    private const MIN_TIMER_INTERVAL_MS = 50;

    private var _pendingLat as Float?;
    private var _pendingLon as Float?;
    private var _pendingRadiusKm as Float?;
    private var _pendingCallback as FetchCallback?;
    private var _lastRequestStartMs as Number?;

    public function initialize() {}

    public function fetch(
        lat as Float,
        lon as Float,
        radiusKm as Float,
        callback as FetchCallback
    ) as Void {
        _pendingLat = lat;
        _pendingLon = lon;
        _pendingRadiusKm = radiusKm;
        _pendingCallback = callback;

        var lastStart = _lastRequestStartMs;
        var elapsed =
            lastStart != null
                ? System.getTimer() - lastStart
                : MIN_REQUEST_INTERVAL_MS;
        if (elapsed >= MIN_REQUEST_INTERVAL_MS) {
            _performFetch();
            return;
        }

        var timer = new Timer.Timer();
        var delay = MIN_REQUEST_INTERVAL_MS - elapsed;
        timer.start(
            method(:_onThrottleElapsed),
            delay < MIN_TIMER_INTERVAL_MS ? MIN_TIMER_INTERVAL_MS : delay,
            false
        );
    }

    // Public so method(:_onThrottleElapsed) isn't optimized away as an unreferenced private symbol.
    public function _onThrottleElapsed() as Void {
        _performFetch();
    }

    private function _performFetch() as Void {
        _lastRequestStartMs = System.getTimer();

        var radiusNm = (_pendingRadiusKm as Float) * 0.539957;
        if (radiusNm < 1.0) {
            radiusNm = 1.0;
        }

        var url =
            BASE_URL +
            "/" +
            (_pendingLat as Float).toString() +
            "/" +
            (_pendingLon as Float).toString() +
            "/" +
            radiusNm.format("%.1f");
        // TEXT_PLAIN, not JSON - the platform's JSON decoder can't handle this API's oversized now/ctime fields.
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType
            =>
            Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN,
        };

        Communications.makeWebRequest(url, null, options, method(:_onReceive));
    }

    // Public so method(:_onReceive) isn't optimized away as an unreferenced private symbol.
    public function _onReceive(
        responseCode as Number,
        data as Dictionary or String or Null
    ) as Void {
        if (responseCode != 200 or !(data instanceof String)) {
            var cb = _pendingCallback;
            if (cb != null) {
                cb.invoke([], false, _isSizeCeilingError(responseCode));
            }
            return;
        }

        _beginIncrementalParse(data as String);
    }

    // Hand-rolled JSON parser, one aircraft object per event-loop tick - see _continueParsingAircraft.

    private const PARSE_BUDGET_MS = 300;

    private var _jsonText as String = "";
    private var _jsonChars as Array<Char> = [] as Array<Char>;
    private var _jsonPos as Number = 0;
    private var _jsonDeadlineMs as Number = 0;
    private var _incrementalResults as Array<Aircraft> = [] as Array<Aircraft>;

    // This API's response always starts {"ac":[ - matched literally, not via a general key search.
    private function _beginIncrementalParse(text as String) as Void {
        _jsonText = text;
        _jsonChars = text.toCharArray();
        _jsonPos = 0;
        _jsonDeadlineMs = System.getTimer() + PARSE_BUDGET_MS;
        _incrementalResults = [] as Array<Aircraft>;

        var ok = true;
        try {
            _skipJsonWs();
            ok = _jsonPos < _jsonChars.size() && _jsonChars[_jsonPos] == '{';
            if (ok) {
                _jsonPos += 1;
                _skipJsonWs();
                ok = _expectLiteral("\"ac\":[");
            }
        } catch (e instanceof JsonParseAbortedException) {
            ok = false;
        }

        if (!ok) {
            var cb = _pendingCallback;
            if (cb != null) {
                cb.invoke([], false, false);
            }
            return;
        }

        _continueParsingAircraft();
    }

    private function _expectLiteral(literal as String) as Boolean {
        var chars = literal.toCharArray();
        var n = _jsonChars.size();
        for (var i = 0; i < chars.size(); i++) {
            if (_jsonPos >= n || _jsonChars[_jsonPos] != chars[i]) {
                return false;
            }
            _jsonPos += 1;
        }
        return true;
    }

    // One object per tick, deliberately - the watchdog is VM-cycle-based (no fixed ms budget), and looping to parse many objects per tick tripped it on a big response.
    public function _continueParsingAircraft() as Void {
        _jsonDeadlineMs = System.getTimer() + PARSE_BUDGET_MS;

        var ok = true;
        var done = false;
        try {
            _skipJsonWs();
            if (_jsonPos >= _jsonChars.size()) {
                ok = false;
                done = true;
            } else {
                var c = _jsonChars[_jsonPos];
                if (c == ',') {
                    _jsonPos += 1;
                    _skipJsonWs();
                    c =
                        _jsonPos < _jsonChars.size()
                            ? _jsonChars[_jsonPos]
                            : ' ';
                }
                if (c == ']') {
                    _jsonPos += 1;
                    done = true;
                } else if (c == '{') {
                    var obj = _parseJsonObject();
                    _incrementalResults.add(new Aircraft(obj));
                } else {
                    ok = false;
                    done = true;
                }
            }
        } catch (e instanceof JsonParseAbortedException) {
            ok = false;
            done = true;
        }

        if (!done) {
            var timer = new Timer.Timer();
            timer.start(
                method(:_continueParsingAircraft),
                MIN_TIMER_INTERVAL_MS,
                false
            );
            return;
        }

        var cb = _pendingCallback;
        if (cb != null) {
            cb.invoke(
                ok ? _incrementalResults : [] as Array<Aircraft>,
                ok,
                false
            );
        }
    }

    // -400/-402/-403 are Communications' own response-size/memory-ceiling codes - distinct from a real connectivity failure.
    private function _isSizeCeilingError(responseCode as Number) as Boolean {
        return (
            responseCode == -400 or responseCode == -402 or responseCode == -403
        );
    }

    private function _checkParseBudget() as Void {
        if (System.getTimer() > _jsonDeadlineMs) {
            throw new JsonParseAbortedException();
        }
    }

    private function _skipJsonWs() as Void {
        var n = _jsonChars.size();
        while (_jsonPos < n) {
            _checkParseBudget();
            var c = _jsonChars[_jsonPos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                _jsonPos += 1;
            } else {
                break;
            }
        }
    }

    private function _parseJsonValue() as Object? {
        _checkParseBudget();
        _skipJsonWs();
        if (_jsonPos >= _jsonChars.size()) {
            return null;
        }
        var c = _jsonChars[_jsonPos];
        if (c == '{') {
            return _parseJsonObject();
        }
        if (c == '[') {
            return _parseJsonArray();
        }
        if (c == '"') {
            return _parseJsonString();
        }
        if (c == 't') {
            _jsonPos += 4;
            return true;
        }
        if (c == 'f') {
            _jsonPos += 5;
            return false;
        }
        if (c == 'n') {
            _jsonPos += 4;
            return null;
        }
        return _parseJsonNumber();
    }

    private function _parseJsonObject() as Dictionary {
        var dict = ({}) as Dictionary;
        _jsonPos += 1; // consume '{'
        _skipJsonWs();
        if (_jsonPos < _jsonChars.size() && _jsonChars[_jsonPos] == '}') {
            _jsonPos += 1;
            return dict;
        }
        while (true) {
            _checkParseBudget();
            _skipJsonWs();
            var key = _parseJsonString();
            _skipJsonWs();
            _jsonPos += 1; // consume ':'
            var value = _parseJsonValue();
            dict[key] = value;
            _skipJsonWs();
            if (_jsonPos >= _jsonChars.size()) {
                break;
            }
            var c = _jsonChars[_jsonPos];
            _jsonPos += 1;
            if (c == '}') {
                break;
            }
            // otherwise assume ',' and continue to the next key
        }
        return dict;
    }

    private function _parseJsonArray() as Array {
        var arr = [] as Array;
        _jsonPos += 1; // consume '['
        _skipJsonWs();
        if (_jsonPos < _jsonChars.size() && _jsonChars[_jsonPos] == ']') {
            _jsonPos += 1;
            return arr;
        }
        while (true) {
            _checkParseBudget();
            arr.add(_parseJsonValue());
            _skipJsonWs();
            if (_jsonPos >= _jsonChars.size()) {
                break;
            }
            var c = _jsonChars[_jsonPos];
            _jsonPos += 1;
            if (c == ']') {
                break;
            }
            // otherwise assume ',' and continue to the next element
        }
        return arr;
    }

    private function _parseJsonString() as String {
        // A truncated response can leave _jsonPos already past the end when this is called - guard like _parseJsonValue does.
        if (_jsonPos >= _jsonChars.size()) {
            return "";
        }
        _jsonPos += 1; // consume opening quote
        var start = _jsonPos;
        var hasEscape = false;
        var n = _jsonChars.size();
        while (_jsonPos < n && _jsonChars[_jsonPos] != '"') {
            _checkParseBudget();
            if (_jsonChars[_jsonPos] == '\\') {
                hasEscape = true;
                _jsonPos += 1;
            }
            _jsonPos += 1;
        }
        var end = _jsonPos;
        _jsonPos += 1; // consume closing quote

        if (!hasEscape) {
            return _jsonText.substring(start, end) as String;
        }
        return _unescapeJsonString(start, end);
    }

    // \uXXXX escapes are dropped, not expanded - not observed in this API's data.
    private function _unescapeJsonString(
        start as Number,
        end as Number
    ) as String {
        var chars = [] as Array<Char>;
        var i = start;
        while (i < end) {
            _checkParseBudget();
            var c = _jsonChars[i];
            if (c == '\\' && i + 1 < end) {
                var next = _jsonChars[i + 1];
                if (next == 'n') {
                    chars.add('\n');
                } else if (next == 't') {
                    chars.add('\t');
                } else if (next == 'r') {
                    chars.add('\r');
                } else if (next == 'u') {
                    i += 6;
                    continue;
                } else {
                    chars.add(next);
                }
                i += 2;
            } else {
                chars.add(c);
                i += 1;
            }
        }
        return StringUtil.charArrayToString(chars);
    }

    private function _parseJsonNumber() as Float {
        var start = _jsonPos;
        var n = _jsonChars.size();
        if (_jsonPos < n && _jsonChars[_jsonPos] == '-') {
            _jsonPos += 1;
        }
        _scanJsonDigits(n);
        if (_jsonPos < n && _jsonChars[_jsonPos] == '.') {
            _jsonPos += 1;
            _scanJsonDigits(n);
        }
        if (
            _jsonPos < n &&
            (_jsonChars[_jsonPos] == 'e' || _jsonChars[_jsonPos] == 'E')
        ) {
            _jsonPos += 1;
            if (
                _jsonPos < n &&
                (_jsonChars[_jsonPos] == '+' || _jsonChars[_jsonPos] == '-')
            ) {
                _jsonPos += 1;
            }
            _scanJsonDigits(n);
        }
        var token = _jsonText.substring(start, _jsonPos) as String;
        return token.toFloat();
    }

    private function _scanJsonDigits(n as Number) as Void {
        while (_jsonPos < n) {
            _checkParseBudget();
            var c = _jsonChars[_jsonPos];
            if (c < '0' || c > '9') {
                break;
            }
            _jsonPos += 1;
        }
    }
}
