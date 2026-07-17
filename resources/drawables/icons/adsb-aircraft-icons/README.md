# ADS-B aircraft icon set (tar1090, extracted)

## Source

This is the aircraft icon set from **tar1090** (https://github.com/wiedehopf/tar1090), the web
interface used by ADSBExchange, adsb.fi, adsb.lol, airplanes.live and most self-hosted
ADS-B receivers. It's the de-facto standard icon set for ADS-B trackers and is actively
maintained (last updated within the last month as of this writing).

Extracted from `html/markers.js` in that repo:
https://raw.githubusercontent.com/wiedehopf/tar1090/master/html/markers.js

**License: GPLv2 or later** (tar1090's license). Using these SVGs in your own app means your
app's distribution of these assets falls under GPL terms — check that this works for your
project. If you need a non-GPL alternative, see "Other sources" below.

## What's in this package

- `icons_svg/` — 92 standalone SVG files, one per unique aircraft silhouette (top-down view).
- `icao_type_designator_to_icon.csv` — 381 rows, ICAO type designator (e.g. `A320`, `B738`,
  `H60`, `C130`) → icon file + a size-scaling factor.
- `icao_type_description_to_icon.csv` — 24-row fallback table keyed by the ICAO type
  *description* code (wing/engine-count/engine-type, e.g. `L2J` = landplane, 2 engines, jet).
  Used when the specific type designator isn't in the first table.
- `adsb_category_to_icon.csv` — 15-row fallback table keyed by the ADS-B broadcast emitter
  category (e.g. `A5` = heavy, `A7` = rotorcraft, `B2` = balloon). Used as the last resort
  when neither of the above matches.
- `icon_manifest.json` — dimensions per icon, for programmatic use.

## Lookup order (this is how tar1090 itself picks an icon)

1. Try the aircraft's specific ICAO type designator in `icao_type_designator_to_icon.csv`.
2. If not found, try the type description code in `icao_type_description_to_icon.csv`.
3. If still not found, fall back to the broadcast category in `adsb_category_to_icon.csv`.
4. If nothing matches, use `unknown.svg`.

Type designator and type description come from the aircraft type database (e.g.
tar1090-db / Mictronics), keyed off the ICAO 24-bit hex address. The category comes straight
off the ADS-B message (DF17/18, type code 31 airborne status, or squawked in ADS-B category
field) — every aircraft broadcasts one of A0–A7, B0–B7, C0–C7 in flight.

## Rendering notes

- Some icons have an `accent` path (windows/canopy lines, cockpit strip) — I rendered those
  as a thin lighter stroke over the main silhouette fill.
- A handful of ground-vehicle/ground-object icons (`ground_emergency`, `ground_service`,
  `ground_unknown`, `ground_fixed`) were originally bitmap-style layered SVGs with
  placeholder colors; I substituted a default dark grey/white color scheme.
- All are top-down silhouettes, sized for a ~30px marker on a map; scale them up for a
  parts catalogue / legend view.

## Other sources (non-GPL alternatives)

- **ADS-B Radar's free SVG set** — https://adsb-radar.com/help/icons.html — covers the common
  airliner types (A320, 747, etc). Free for personal/commercial use with a required backlink
  to ADS-B Radar; individually downloadable.
- **AircraftShapesSVG (RexKramer1 / BelugaProject)** —
  https://github.com/RexKramer1/AircraftShapesSVG — a different top-view shape set plus a
  tutorial for drawing your own; check the repo for current license terms before using.
- **VirtualRadarServer "PlaneObjects"** — a much older, simpler bitmap icon set bundled with
  Virtual Radar Server, if you want something more basic.
