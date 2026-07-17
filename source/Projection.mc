import Toybox.Lang;
import Toybox.Math;

// Equirectangular approximation - accurate enough at the few-tens-of-km radii this radar operates at.
module Projection {
    const METERS_PER_DEG_LAT = 111320.0;

    // [dxKm, dyKm] offset of (lat, lon) from center; +x = east, +y = north.
    function deltaKm(
        centerLat as Float,
        centerLon as Float,
        lat as Float,
        lon as Float
    ) as Array<Float> {
        var metersPerDegLon =
            METERS_PER_DEG_LAT * Math.cos(Math.toRadians(centerLat));
        var dxM = (lon - centerLon) * metersPerDegLon;
        var dyM = (lat - centerLat) * METERS_PER_DEG_LAT;
        return [dxM / 1000.0, dyM / 1000.0];
    }

    // Screen +y is down, so dyKm is negated here.
    function toScreen(
        centerLat as Float,
        centerLon as Float,
        lat as Float,
        lon as Float,
        screenCx as Number,
        screenCy as Number,
        radiusPx as Number,
        radiusKm as Float
    ) as Array<Number> {
        var d = deltaKm(centerLat, centerLon, lat, lon);
        var pxPerKm = radiusPx / radiusKm;
        var x = screenCx + d[0] * pxPerKm;
        var y = screenCy - d[1] * pxPerKm;
        return [x.toNumber(), y.toNumber()];
    }

    function distanceKm(
        centerLat as Float,
        centerLon as Float,
        lat as Float,
        lon as Float
    ) as Float {
        var d = deltaKm(centerLat, centerLon, lat, lon);
        return Math.sqrt(d[0] * d[0] + d[1] * d[1]);
    }

    // Inverse of toScreen - how far the focus point must shift for on-screen content to move by (dxPx, dyPx).
    function screenDeltaToLatLon(
        dxPx as Number,
        dyPx as Number,
        focusLat as Float,
        radiusPx as Number,
        radiusKm as Float
    ) as [Float, Float] {
        var pxPerKm = radiusPx / radiusKm;
        var dxKm = -dxPx / pxPerKm;
        var dyKm = dyPx / pxPerKm;
        var metersPerDegLon =
            METERS_PER_DEG_LAT * Math.cos(Math.toRadians(focusLat));
        var dLon = (dxKm * 1000.0) / metersPerDegLon;
        var dLat = (dyKm * 1000.0) / METERS_PER_DEG_LAT;
        return [dLat, dLon];
    }
}
