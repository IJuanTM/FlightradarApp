[x] Run a /code-review pass

[ ] Update README

[ ] MapClient.mc:64 - timed-out tile request isn't cancelled; a late real response can be matched against whatever tile is now `_current`, drawing the wrong bitmap at the wrong screen position

[ ] RadarView.mc:1149 - AirplanesLiveClient never nulls `_pendingCallback` after use, so a late real fetch response can re-invoke `_onFetchResult` a second time after a synthetic timeout already fired, clobbering backoff state and re-processing stale aircraft data

[ ] RadarView.mc:576 - selected-aircraft track/route retry after a synthetic timeout races OpenSkyClient's single-slot `_pendingTrackCallback`; the original or the retry's real response can be silently dropped or misattributed

[ ] RadarView.mc:217 - FETCH_TIMEOUT_MS (3000ms, down from 10000ms) now triggers a real failure/"No Signal" flash on ordinary 3-9s network latency, not just genuine failures

[ ] RadarView.mc:3462 (and ~3646) - "Heading" label still reads `ac.track` instead of the new `ac.heading` field icon rotation uses; blank for aircraft with valid heading but no track (e.g. taxiing)

[ ] RadarView.mc:1073 - `_fetchSelectedTrack`/`_fetchSelectedRoute` don't call `_mapClient.pause()/resume()` like `_fetchNow` does, so they can collide with in-flight map tile requests on the shared phone-request channel

[ ] RadarView.mc:1266 - background map raster is never clipped (no `setClip`) to the circular radar boundary; bleeds into the annulus toward the screen edge

[ ] RadarView.mc:1286 - disabling `showBackgroundMap` doesn't prune MapClient's queue or reliably reset needed-tile state if toggled off before the first tile ever resolved, which can permanently pin the aircraft-poll interval to its fastest tier

[ ] RadarView.mc:266 - ANIM_TICK_MS halved (200ms -> 100ms) unconditionally; `batterySaverMode` only scales poll interval, not this, so battery saver no longer halves background tick work like it used to

[ ] RadarView.mc:1534 - `pruneQueue()` only drops queued tiles, not the in-flight one; after a zoom change a stale in-flight tile can run to completion (up to 3s) while blocking the aircraft poll via `isBusy()`
