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

    const WEB_MERCATOR_EQUATOR_M_PER_PX_AT_Z0 = 156543.03392;

    // Standard 256px-tile convention, unadjusted - see MapClient._dispatch for the correction.
    function webMercatorZoom(
        lat as Float,
        radiusKm as Float,
        radiusPx as Number
    ) as Float {
        var metersPerPx = (radiusKm * 1000.0) / radiusPx;
        var equatorMPerPx =
            WEB_MERCATOR_EQUATOR_M_PER_PX_AT_Z0 * Math.cos(Math.toRadians(lat));
        return Math.log(equatorMPerPx / metersPerPx, 2.0).toFloat();
    }

    // Inverse of webMercatorZoom - the px-per-km scale a given zoom represents at this latitude.
    function pxPerKmForZoom(lat as Float, zoom as Float) as Float {
        var equatorMPerPx =
            WEB_MERCATOR_EQUATOR_M_PER_PX_AT_Z0 * Math.cos(Math.toRadians(lat));
        var metersPerPx = equatorMPerPx / Math.pow(2.0, zoom);
        return 1000.0 / metersPerPx;
    }
}
