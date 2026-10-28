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
        var dLon = lon - centerLon;
        // Shortest way round, so points just across the antimeridian stay near instead of 360 degrees away.
        if (dLon > 180.0) {
            dLon -= 360.0;
        } else if (dLon < -180.0) {
            dLon += 360.0;
        }
        return [
            (dLon * metersPerDegLon) / 1000.0,
            ((lat - centerLat) * METERS_PER_DEG_LAT) / 1000.0,
        ];
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

    // Inverse of ScreenProjection.toScreen - how far the focus point must shift for on-screen content to move by (dxPx, dyPx).
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
        return [
            (dyKm * 1000.0) / METERS_PER_DEG_LAT,
            (dxKm * 1000.0) / metersPerDegLon,
        ];
    }

    const WEB_MERCATOR_EQUATOR_M_PER_PX_AT_Z0 = 156543.03392;

    // Standard 256px-tile convention, unadjusted - callers apply their own provider-specific correction.
    function webMercatorZoom(
        lat as Float,
        radiusKm as Float,
        radiusPx as Number
    ) as Float {
        return Math.log(
            (WEB_MERCATOR_EQUATOR_M_PER_PX_AT_Z0 *
                Math.cos(Math.toRadians(lat))) /
                ((radiusKm * 1000.0) / radiusPx),
            2.0
        ).toFloat();
    }

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
        return [Math.floor(x).toNumber(), Math.floor(y).toNumber()];
    }

    function kmToDegLat(km as Float) as Float {
        return km / (METERS_PER_DEG_LAT / 1000.0);
    }

    // Longitude degrees shrink in real distance away from the equator (cos(lat)) - unlike latitude.
    function kmToDegLon(km as Float, atLat as Float) as Float {
        return (
            (km * 1000.0) /
            (METERS_PER_DEG_LAT * Math.cos(Math.toRadians(atLat)))
        );
    }

    // Top-left corner of the tile.
    function tileToLatLon(
        x as Number,
        y as Number,
        zoom as Number
    ) as [Float, Float] {
        var n = Math.pow(2.0, zoom.toFloat());
        var lonDeg = (x.toFloat() / n) * 360.0 - 180.0;
        var latRad =
            Math.atan(
                Math.pow(Math.E, Math.PI * (1.0 - (2.0 * y.toFloat()) / n))
            ) *
                2.0 -
            Math.PI / 2.0;
        return [Math.toDegrees(latRad).toFloat(), lonDeg];
    }
}
