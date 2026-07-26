[x] Darker map / background map provider - on TomTom tiles (`basic/night`), seam bug confirmed fixed on-device. Actual darkening not done - skipped for now (see memory).

[ ] Clicking on a craft does not cause the map to reload, even when there is a lot of empty black space showing. And a check, does it refetch the aircraft around the craft when selected?

[ ] Check the whole CENTER OFFSET 1px thing, is it really necessary, or left over from old stuff with the icon centering - likely related to the same Projection.toScreen truncation just fixed for map tiles above (toScreen still truncates for everything else - aircraft, grid, etc. - this item is about whether that also needs the toScreenF treatment elsewhere).

[ ] Map zoom levels see what tweaks are possible for visibility of labels, roads, buildings, etc.

[ ] Run a /code-review pass

[ ] Update README
