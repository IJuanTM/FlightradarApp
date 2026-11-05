import Toybox.Lang;

module FetchTimeout {
    // Round trips through the phone relay routinely take 3-9s - anything lower flags normal latency as "No Signal".
    const MS = 10000;

    // An expired fetch is failed by its owner, not cancelled - cancelAllRequests() crashed on hardware.
    function expired(startedAt as Number?, now as Number) as Boolean {
        return startedAt != null and now - startedAt > MS;
    }

    // Other negative codes (bad body, oversized, unsupported type) would repeat identically.
    // 0 is a watchdog's fake failure, whose real request is still out.
    function isTransient(code as Number) as Boolean {
        return (
            code >= 500 ||
            (code < 0 && code >= -5) ||
            code == -101 ||
            code == -103 ||
            code == -300 ||
            code == -1004
        );
    }
}
