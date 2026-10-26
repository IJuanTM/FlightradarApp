import Toybox.Lang;

module FetchTimeout {
    // Round trips through the phone relay routinely take 3-9s - anything lower flags normal latency as "No Signal".
    const MS = 10000;

    // An expired fetch is failed by its owner, not cancelled - cancelAllRequests() crashed on hardware.
    function expired(startedAt as Number?, now as Number) as Boolean {
        return startedAt != null and now - startedAt > MS;
    }
}
