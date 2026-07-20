# TODO

## Refactor DrawUtil's text-marker system (`^`, `!`, `~`)

`DrawUtil` currently renders degree circles, warning icons, and dim-color
annotations by embedding sentinel characters (`DEGREE_MARK`, `WARNING_MARK`,
`DIM_MARK`) inside plain value strings, then hunting for them with
`.find()`/`.substring()` at draw time (`_findMarker`, `markedTextWidth`,
`drawMarkedText`, `dimSplitTextWidth`, `drawDimSplitText`).

Problem: encoding rendering instructions as magic characters in what's
otherwise display text is fragile - it relies on those characters never
appearing in real data, and every caller has to know which markers can't be
combined in one string.

Better: represent a value as an explicit list of typed segments (built
directly by the caller, not parsed back out of a string) - e.g. a plain-text
run with its own color, a degree-glyph marker, a warning-glyph marker - and
have the drawing code just walk that list instead of re-discovering intent
from characters embedded in text.

(Look at ../TerminalWatchface how this code does it with the rendering of the icons (no weird marker system))

## Route info can show the wrong (previous) flight

OpenSky's `/flights/aircraft` is batch-processed overnight, so a currently
in-progress flight never appears there - whatever segment comes back is
always the aircraft's last *completed* flight. For a quick out-and-back/
turnaround, that previous leg can be the reverse of the one you're actually
watching, which reads as "flipped" departure/arrival even though nothing is
actually swapped in our code (see `network_data_history.md`, 2026-07-20).

No fix possible with this endpoint alone. Look into whether another free,
no-auth API/endpoint (or a different OpenSky endpoint) can give a real
in-progress flight's route, or at least add a way to tell the user the shown
route might be stale (e.g. only show it if the segment's `lastSeen` is recent
enough to plausibly be the current flight, otherwise show "Unknown").

## 
