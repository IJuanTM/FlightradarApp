import Toybox.Lang;

// Non-literal entries index the arrays below - read them at runtime only, never from another file's const initializer.
module Palette {
    // The only opacities used anywhere in this app.
    const ALPHA_15 = 0x26;
    const ALPHA_25 = 0x40;
    const ALPHA_35 = 0x59;
    const ALPHA_50 = 0x80;
    const ALPHA_55 = 0x8c;
    const ALPHA_95 = 0xf2;

    const GRAYS =
        [0x111111, 0x333333, 0x555555, 0x777777, 0xaaaaaa, 0xcccccc] as
        Array<Number>;

    // Not an accent - kept out of HUES below, which is hues only.
    const WHITE = 0xffffff;

    // User-specified palette - every channel is 0x55/0xa5/0xfa, hue-sorted.
    const HUES =
        [
            0xfa5555, // 0  red
            0xfaa555, // 1  orange
            0xfafa55, // 2  yellow
            0x55fa55, // 3  green
            0x55fafa, // 4  cyan
            0x55a5fa, // 5  azure
            0x5555fa, // 6  blue
            0xa555fa, // 7  purple
            0xfa55fa, // 8  magenta
            0xfa55a5, // 9  rose
        ] as Array<Number>;

    // Shared so RadarView's compact ring and AircraftDetailView's full-screen ring match.
    const RING = 0xaaaaaa;
    const RING_ALPHA = ALPHA_25;
    const BOUNDARY_ALPHA = ALPHA_50;
    const TICK_ALPHA = ALPHA_55;
    const MINOR_TICK_ALPHA = ALPHA_35;
    const GRID = GRAYS[3];
    const GRID_ALPHA = ALPHA_15;
    const GRID_LABEL = GRAYS[3];
    const TRAIL_ALPHA = ALPHA_95;
    // Ground/taxi trail segments dim the trail's own color instead of using gray, so the dashed part still reads as one track.
    const TRAIL_GROUND_ALPHA = ALPHA_55;
    const TEXT = GRAYS[5];
    const ROW_LABEL = 0x999999;

    const USER = HUES[4]; // cyan
    const AIRPORT = HUES[5]; // azure
    // Green contrasts well against white, the default aircraft color.
    const SELECTED = HUES[3]; // green
    const EMERGENCY = HUES[0]; // red

    const AIRCRAFT_DEFAULT = WHITE;
    const AIRCRAFT_LIGHT = HUES[2]; // yellow
    const AIRCRAFT_HEAVY = HUES[6]; // blue
    const AIRCRAFT_FAST = HUES[7]; // purple
    const HELICOPTER = HUES[1]; // orange
    const MILITARY = HUES[8]; // magenta
    const GROUND = HUES[9]; // rose

    // "Grey" full-detail values are white - label and value would read as the same dim tone otherwise.
    const DETAIL_VALUE = WHITE;
    // Route's loading/unknown/failed states only, to read as "not resolved" rather than a fact.
    const ROUTE_DIM = GRID_LABEL;
    // Identity/reference fields - not grey, row labels are already grey.
    const IDENTITY = HUES[4]; // cyan
    const ENV = HUES[7]; // purple

    // Detail panel value colors - not tied to aircraft category, just distinguishing fields at a glance.
    const ALT = HUES[6]; // blue
    const SPEED = HUES[2]; // yellow
    // Orange, not cyan - would collide with IDENTITY (also cyan).
    const HDG = HUES[1]; // orange
    const SQUAWK = HUES[8]; // magenta
    // Shared status semantics across top/detail panels: green = done/good, orange = caution.
    const SUCCESS = HUES[3]; // green
    const WARN = HUES[1]; // orange
}
