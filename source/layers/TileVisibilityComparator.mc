import Toybox.Lang;
import Toybox.Math;

// Sorts needed tiles by on-screen visible area; the center-of-screen tile is always pinned first.
class TileVisibilityComparator {
    private var _centerTx as Number;
    private var _centerTy as Number;
    private var _tileZ as Number;
    private var _focusLat as Float;
    private var _focusLon as Float;
    private var _cx as Number;
    private var _cy as Number;
    private var _radiusPx as Number;
    private var _radiusKm as Float;
    private var _screenW as Number;
    private var _screenH as Number;

    public function initialize(
        centerTx as Number,
        centerTy as Number,
        tileZ as Number,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        screenW as Number,
        screenH as Number
    ) {
        _centerTx = centerTx;
        _centerTy = centerTy;
        _tileZ = tileZ;
        _focusLat = focusLat;
        _focusLon = focusLon;
        _cx = cx;
        _cy = cy;
        _radiusPx = radiusPx;
        _radiusKm = radiusKm;
        _screenW = screenW;
        _screenH = screenH;
    }

    public function compare(a as Object?, b as Object?) as Number {
        var ta = a as [Number, Number, Number, Number];
        var tb = b as [Number, Number, Number, Number];
        var aIsCenter = ta[1] == _centerTx and ta[2] == _centerTy;
        var bIsCenter = tb[1] == _centerTx and tb[2] == _centerTy;
        if (aIsCenter and !bIsCenter) {
            return -1;
        }
        if (bIsCenter and !aIsCenter) {
            return 1;
        }
        var areaDiff = _visibleArea(tb[1], tb[2]) - _visibleArea(ta[1], ta[2]);
        return areaDiff > 0 ? 1 : areaDiff < 0 ? -1 : 0;
    }

    private function _visibleArea(tx as Number, ty as Number) as Float {
        var topLeftLatLon = Projection.tileToLatLon(tx, ty, _tileZ);
        var bottomRightLatLon = Projection.tileToLatLon(tx + 1, ty + 1, _tileZ);
        var topLeft = Projection.toScreenF(
            _focusLat,
            _focusLon,
            topLeftLatLon[0],
            topLeftLatLon[1],
            _cx,
            _cy,
            _radiusPx,
            _radiusKm
        );
        var bottomRight = Projection.toScreenF(
            _focusLat,
            _focusLon,
            bottomRightLatLon[0],
            bottomRightLatLon[1],
            _cx,
            _cy,
            _radiusPx,
            _radiusKm
        );
        return (
            (
                Math.max(
                    Math.min(bottomRight[0], _screenW.toFloat()) -
                        Math.max(topLeft[0], 0.0),
                    0.0
                ) *
                    Math.max(
                        Math.min(bottomRight[1], _screenH.toFloat()) -
                            Math.max(topLeft[1], 0.0),
                        0.0
                    )
            ) as Float
        );
    }
}
