import Toybox.Lang;
import Toybox.Math;

// Projection.deltaKm's equirectangular math with its scale fixed for one frame - cos(focusLat) once, not per point.
class ScreenProjection {
    public var focusLat as Float;
    public var focusLon as Float;
    public var cx as Number;
    public var cy as Number;
    public var radiusPx as Number;
    public var radiusKm as Float;
    private var _pxPerDegLat as Float;
    private var _pxPerDegLon as Float;

    public function initialize(
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float
    ) {
        self.focusLat = focusLat;
        self.focusLon = focusLon;
        self.cx = cx;
        self.cy = cy;
        self.radiusPx = radiusPx;
        self.radiusKm = radiusKm;
        _pxPerDegLat =
            ((Projection.METERS_PER_DEG_LAT / 1000.0) * radiusPx) / radiusKm;
        _pxPerDegLon = _pxPerDegLat * Math.cos(Math.toRadians(focusLat));
    }

    // Unrounded, so callers lining up several points can round once at the end rather than each independently.
    public function toScreenF(lat as Float, lon as Float) as [Float, Float] {
        var dLon = lon - focusLon;
        if (dLon > 180.0) {
            dLon -= 360.0;
        } else if (dLon < -180.0) {
            dLon += 360.0;
        }
        return [cx + dLon * _pxPerDegLon, cy - (lat - focusLat) * _pxPerDegLat];
    }

    // Rounded, not truncated - .toNumber() truncates toward zero, biasing every point inward.
    public function toScreen(lat as Float, lon as Float) as [Number, Number] {
        var p = toScreenF(lat, lon);
        return [Math.round(p[0]).toNumber(), Math.round(p[1]).toNumber()];
    }
}
