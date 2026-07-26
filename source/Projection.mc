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
        var p = toScreenF(
            centerLat,
            centerLon,
            lat,
            lon,
            screenCx,
            screenCy,
            radiusPx,
            radiusKm
        );
        // Rounded, not truncated - .toNumber() truncates toward zero, biasing every point inward.
        return [Math.round(p[0]).toNumber(), Math.round(p[1]).toNumber()];
    }

    // Same as toScreen but stays in Float - two points each rounded independently can still land
    // inconsistently; callers needing several points to line up exactly should round once, at the end.
    function toScreenF(
        centerLat as Float,
        centerLon as Float,
        lat as Float,
        lon as Float,
        screenCx as Number,
        screenCy as Number,
        radiusPx as Number,
        radiusKm as Float
    ) as [Float, Float] {
        var d = deltaKm(centerLat, centerLon, lat, lon);
        var pxPerKm = radiusPx / radiusKm;
        var x = screenCx + d[0] * pxPerKm;
        var y = screenCy - d[1] * pxPerKm;
        return [x, y];
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

    // Standard 256px-tile convention, unadjusted - callers apply their own provider-specific correction.
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

    const EULERS_NUMBER = 2.718281828459045;

    // Standard slippy-map tile index containing (lat, lon) at a given integer zoom.
    function latLonToTile(
        lat as Float,
        lon as Float,
        zoom as Number
    ) as [Number, Number] {
        var n = Math.pow(2.0, zoom.toFloat());
        var latRad = Math.toRadians(lat);
        var x = ((lon + 180.0) / 360.0) * n;
        var y =
            ((1.0 -
                Math.ln(Math.tan(latRad) + 1.0 / Math.cos(latRad)) / Math.PI) /
                2.0) *
            n;
        return [x.toNumber(), y.toNumber()];
    }

    // Inverse of latLonToTile - the lat/lon of a tile's top-left corner.
    function tileToLatLon(
        x as Number,
        y as Number,
        zoom as Number
    ) as [Float, Float] {
        var n = Math.pow(2.0, zoom.toFloat());
        var lonDeg = (x.toFloat() / n) * 360.0 - 180.0;
        var latRad =
            Math.atan(
                Math.pow(
                    EULERS_NUMBER,
                    Math.PI * (1.0 - (2.0 * y.toFloat()) / n)
                )
            ) *
                2.0 -
            Math.PI / 2.0;
        return [Math.toDegrees(latRad).toFloat(), lonDeg];
    }
}
