[ ] Darker map still not done - styleCustomization (background/roads hex colors) reliably 400'd, both a literal "#" and a pre-encoded "%23" failed, rgb() syntax also rejected. Removed entirely to restore the working map. Root cause not confirmed - needs a fresh, isolated approach, not another blind guess.

- See @geoapify_style_editor_source for the source code of the style editor page. This is set to the dark_matter theme so in the table you can find 1. the different available options to tweak and 2. the default values they have. Same default values should be tweaked to the same new, darker, value.
- And this is an example of how the query should look `&styleCustomization=background:%23545454|water:%23898989|landcover_ice_shelf:%235e5e5e|landcover_wood:%23232323|water_name:rgba(28%2C28%2C28%2C0.7)|aeroway-runway-casing:rgba(40%2C60%2C60%2C0.8)` (I just entered some random values).

[x] Re-tested via a real connectivity-loss test - found a real, separate bug: a stuck in-flight request that never explicitly failed (so the retry logic never ran) eventually resolved on reconnect using its original pre-disconnect coordinates, and RadarView accepted it unconditionally, showing stale position/zoom even after the user had since panned/zoomed. Fixed: \_onMapReceive now discards a response whose echoed (lat,lon,zoom) don't exactly match the current target and forces a fresh attempt. Not yet re-tested on-device.

[ ] Attribution-cover black box leaves 1-2px poking through (bottom/right) - real rounding bug found (bare .toNumber() truncates instead of rounds, mismatching the AffineTransform-rendered bitmap edge), fixed with Math.round + a 2px safety margin. Not yet re-tested on-device.

[ ] Check the whole CENTER OFFSET 1px thing, is it really necessary, or left over from old stuff with the icon centering.

[ ] Run a /code-review pass

[ ] Update README

[x] Track of planes on ground is dashed but only the fetched track, not the rendered track that happens after the fetch, fix it. Fixed: \_drawDashedLine now carries its dash phase across consecutive segments instead of restarting at each one. Confirmed working on-device.

[x] Rotation of grounded (taxiing) planes is wrong, is that a bug? Fixed: rotation now uses a new `Aircraft.heading` field (true_heading > mag_heading > track priority) instead of raw `track`, which the feed omits/leaves stale at low groundspeed. Confirmed working on-device.

- Touchdown straight-line gap (dashed line jumps straight from last fetched point to current live position after landing): confirmed as an OpenSky data-completeness limitation, not a bug - OpenSky's historical track often lacks taxi/surface waypoints, so there's a real gap between the last fetched point and the first live-polled point. User decided to leave as-is.

[ ] Clicking on a craft does not cause the map to reload, even when there is a lot of empty black space showing. And a check, does it refetch the aircraft around the craft when selected?
