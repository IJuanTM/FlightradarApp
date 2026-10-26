import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

class BackgroundMap {
    // Safety valve, not the primary bound (_pruneStaleTilesCoveredBy is) - in STD units, where a HI tile weighs 4.
    private const STALE_HARD_CEILING_STD_UNITS = 20;
    // A repeatedly failing tile keeps the backlog pending forever - this caps how long stale tiles are held regardless.
    private const STALE_MAX_AGE_MS = 30000;
    private const FETCH_DEBOUNCE_MS = 100;
    private const DEBOUNCE_RESET_THRESHOLD_KM = 0.05;
    private const INITIAL_RETRY_BACKOFF_MS = 2000;
    private const MAX_RETRY_BACKOFF_MS = 32000;
    // Smaller pan buffer traded for tile count - a bigger margin needs too many tiles to fetch sequentially at native zoom.
    private const OVERSCAN_FACTOR = 1.1;
    private const REFETCH_MARGIN_FACTOR = 0.75;
    // A 6th concurrently-cached 512x512-class tile reliably fails - stay comfortably under that.
    private const MAX_TILES_FOR_HI_RES = 5;

    // Shared request channel - the aircraft poll and the selection fetches pause it while they run.
    public var client as MapTileClient = new MapTileClient(
        method(:_onTileReceive)
    );

    // bitmap, x, y, z, tileSize, topLeftLatLon, bottomRightLatLon - corners computed once at fetch time, not per draw.
    typedef MapTile as
        [
            Graphics.BitmapType,
            Number,
            Number,
            Number,
            Number,
            [Float, Float],
            [Float, Float],
        ];
    private var _tiles as Dictionary<String, MapTile> = {};
    // Style/dark combo the cache was fetched under - cache keys don't include style, so a change here must evict it all.
    private var _cachedStyleKey as String?;
    private var _neededKeys as Dictionary<String, Boolean> = {};
    // Mirrors _neededKeys with the actual tuples, for the draw pass's pending-tile placeholder.
    private var _neededTiles as Array<[Number, Number, Number, Number]> = [];
    // Previous zoom's tiles, drawn scaled to the new view until superseded by the real tile.
    private var _staleTiles as Array<MapTile> = [];
    private var _staleTilesSetAtMs as Number?;

    private var _pendingZoomIndex as Number?;
    private var _pendingLat as Float?;
    private var _pendingLon as Float?;
    private var _pendingSinceMs as Number?;
    // A followed aircraft's position never holds still long enough to pass the debounce on its own.
    private var _forceRefetch as Boolean = false;

    // Refetch checks compare against this, not the received tiles, to avoid re-requesting a slow fetch.
    private var _requestedZoomIndex as Number?;
    private var _requestedLat as Float?;
    private var _requestedLon as Float?;
    // Shared across all tiles, since only one tile request is ever in flight.
    private var _nextRetryAtMs as Number?;
    private var _retryBackoffMs as Number = INITIAL_RETRY_BACKOFF_MS;

    private var _edgeMarginPx as Number = 0;
    private var _font as Graphics.FontType = Graphics.FONT_XTINY;
    private var _loadingText as String = "";

    public function initialize() {}

    public function onLayout(
        edgeMarginPx as Number,
        font as Graphics.FontType
    ) as Void {
        _edgeMarginPx = edgeMarginPx;
        _font = font;
        _loadingText = WatchUi.loadResource(Rez.Strings.MapLoading) as String;
    }

    public function requestRefetch() as Void {
        _forceRefetch = true;
    }

    public function syncStyle() as Void {
        var styleKey = Settings.mapStyle + (Settings.mapDarkMode ? "d" : "l");
        var cachedStyleKey = _cachedStyleKey;
        if (
            cachedStyleKey != null and
            !(cachedStyleKey as String).equals(styleKey)
        ) {
            _reset();
        }
        _cachedStyleKey = styleKey;
    }

    // Always prunes, even with an empty cache - a still-queued tile would otherwise keep the shared channel busy for the aircraft poll.
    public function release() as Void {
        client.pruneQueue(({}) as Dictionary<String, Boolean>);
        if (
            _tiles.size() > 0 or
            _staleTiles.size() > 0 or
            _neededTiles.size() > 0
        ) {
            _reset();
        }
    }

    public function expireStaleTiles(now as Number) as Void {
        if (
            _staleTiles.size() > 0 and
            (now - (_staleTilesSetAtMs as Number) > STALE_MAX_AGE_MS or
                !_hasPendingBacklog())
        ) {
            _staleTiles = [];
            _staleTilesSetAtMs = null;
        }
    }

    // Releases graphics-pool memory immediately - map tile bitmaps are a real OOM risk on device.
    private function _reset() as Void {
        _tiles = {};
        _staleTiles = [];
        _staleTilesSetAtMs = null;
        _neededKeys = {};
        _neededTiles = [];
        // Also clears the last-requested view - otherwise re-enabling without movement never refetches.
        _requestedLat = null;
        // MapTileClient's own dedup key is just z/x/y/tileSize, blind to the style change underneath it.
        client.pruneQueue(({}) as Dictionary<String, Boolean>);
    }

    // True when it queued a new tile set.
    public function maybeFetch(
        focusLat as Float,
        focusLon as Float,
        radiusPx as Number,
        radiusKm as Float,
        cx as Number,
        cy as Number,
        screenW as Number,
        screenH as Number
    ) as Boolean {
        var zoomIndex = Settings.zoomIndex;
        var now = System.getTimer();
        if (_forceRefetch) {
            _forceRefetch = false;
            _pendingZoomIndex = zoomIndex;
            _pendingLat = focusLat;
            _pendingLon = focusLon;
            _pendingSinceMs = now - FETCH_DEBOUNCE_MS;
        }
        var pendingLat = _pendingLat;
        var stillSameTarget =
            _pendingZoomIndex == zoomIndex and
            pendingLat != null and
            Projection.distanceKm(
                pendingLat as Float,
                _pendingLon as Float,
                focusLat,
                focusLon
            ) <= DEBOUNCE_RESET_THRESHOLD_KM;

        if (!stillSameTarget or _pendingSinceMs == null) {
            _pendingZoomIndex = zoomIndex;
            _pendingLat = focusLat;
            _pendingLon = focusLon;
            _pendingSinceMs = now;
            return false;
        }
        if (now - (_pendingSinceMs as Number) < FETCH_DEBOUNCE_MS) {
            return false;
        }

        var nextRetryAt = _nextRetryAtMs;
        if (nextRetryAt != null and now < (nextRetryAt as Number)) {
            return false;
        }

        var screenHalfPx = radiusPx + _edgeMarginPx;
        var overscanMarginKm =
            (screenHalfPx * (OVERSCAN_FACTOR - 1.0) * radiusKm) / radiusPx;

        var requestedLat = _requestedLat;
        var needsRefetch =
            _requestedZoomIndex != zoomIndex or
            requestedLat == null or
            Projection.distanceKm(
                requestedLat as Float,
                _requestedLon as Float,
                focusLat,
                focusLon
            ) >
                overscanMarginKm * REFETCH_MARGIN_FACTOR;
        if (!needsRefetch) {
            return false;
        }

        // Native zoom, not shifted coarser - tile count is controlled via OVERSCAN_FACTOR instead.
        var tileZ = Math.round(
            Projection.webMercatorZoom(focusLat, radiusKm, radiusPx)
        ).toNumber();
        var mapHalfPx = screenHalfPx * OVERSCAN_FACTOR;
        // Args are negated - this returns how far the focus must shift for content to move by (dx,dy).
        var cornerA = Projection.screenDeltaToLatLon(
            mapHalfPx.toNumber(),
            mapHalfPx.toNumber(),
            focusLat,
            radiusPx,
            radiusKm
        );
        var cornerB = Projection.screenDeltaToLatLon(
            -mapHalfPx.toNumber(),
            -mapHalfPx.toNumber(),
            focusLat,
            radiusPx,
            radiusKm
        );
        var tileA = Projection.latLonToTile(
            focusLat + (cornerA[0] as Float),
            focusLon + (cornerA[1] as Float),
            tileZ
        );
        var tileB = Projection.latLonToTile(
            focusLat + (cornerB[0] as Float),
            focusLon + (cornerB[1] as Float),
            tileZ
        );
        var minTileX = tileA[0] < tileB[0] ? tileA[0] : tileB[0];
        var maxTileX = tileA[0] > tileB[0] ? tileA[0] : tileB[0];
        var minTileY = tileA[1] < tileB[1] ? tileA[1] : tileB[1];
        var maxTileY = tileA[1] > tileB[1] ? tileA[1] : tileB[1];

        var tileSize =
            (maxTileX - minTileX + 1) * (maxTileY - minTileY + 1) <=
            MAX_TILES_FOR_HI_RES
                ? client.TILE_SIZE_HI
                : client.TILE_SIZE_STD;

        var centerTile = Projection.latLonToTile(focusLat, focusLon, tileZ);
        var neededKeys = ({}) as Dictionary<String, Boolean>;
        var neededList = [] as Array<[Number, Number, Number, Number]>;
        for (var tx = minTileX; tx <= maxTileX; tx++) {
            for (var ty = minTileY; ty <= maxTileY; ty++) {
                // The tile range is a square, but the display is round - its corner tiles can lie wholly outside it.
                if (
                    !_tileTouchesCircle(
                        tx,
                        ty,
                        tileZ,
                        focusLat,
                        focusLon,
                        cx,
                        cy,
                        radiusPx,
                        radiusKm,
                        mapHalfPx
                    )
                ) {
                    continue;
                }
                neededKeys[client.tileKeyFor(tileZ, tx, ty, tileSize)] = true;
                neededList.add([tileZ, tx, ty, tileSize]);
            }
        }
        neededList.sort(
            new TileVisibilityComparator(
                centerTile[0],
                centerTile[1],
                tileZ,
                focusLat,
                focusLon,
                cx,
                cy,
                radiusPx,
                radiusKm,
                screenW,
                screenH
            )
        );

        // Only a real zoom change keeps the old set - _pruneStaleTilesCoveredBy evicts each stale tile as its area is replaced.
        if (
            _requestedZoomIndex != null and
            _requestedZoomIndex != zoomIndex and
            _tiles.size() > 0
        ) {
            _staleTiles = _tiles.values();
            _staleTilesSetAtMs = now;
        }

        _requestedZoomIndex = zoomIndex;
        _requestedLat = focusLat;
        _requestedLon = focusLon;
        _neededKeys = neededKeys;
        _neededTiles = neededList;

        var cacheKeys = _tiles.keys();
        for (var i = 0; i < cacheKeys.size(); i++) {
            var key = cacheKeys[i] as String;
            if (!neededKeys.hasKey(key)) {
                _tiles.remove(key);
            }
        }
        client.pruneQueue(neededKeys);

        for (var i = 0; i < neededList.size(); i++) {
            var t = neededList[i];
            var key = client.tileKeyFor(
                t[0] as Number,
                t[1] as Number,
                t[2] as Number,
                t[3] as Number
            );
            if (!_tiles.hasKey(key)) {
                client.requestTile(
                    t[0] as Number,
                    t[1] as Number,
                    t[2] as Number,
                    t[3] as Number
                );
            }
        }
        return true;
    }

    private function _tileTouchesCircle(
        tx as Number,
        ty as Number,
        tileZ as Number,
        focusLat as Float,
        focusLon as Float,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        circleR as Float
    ) as Boolean {
        var topLeftLatLon = Projection.tileToLatLon(tx, ty, tileZ);
        var bottomRightLatLon = Projection.tileToLatLon(tx + 1, ty + 1, tileZ);
        var topLeft = Projection.toScreenF(
            focusLat,
            focusLon,
            topLeftLatLon[0],
            topLeftLatLon[1],
            cx,
            cy,
            radiusPx,
            radiusKm
        );
        var bottomRight = Projection.toScreenF(
            focusLat,
            focusLon,
            bottomRightLatLon[0],
            bottomRightLatLon[1],
            cx,
            cy,
            radiusPx,
            radiusKm
        );
        var nearestX =
            cx < topLeft[0]
                ? topLeft[0]
                : cx > bottomRight[0]
                  ? bottomRight[0]
                  : cx;
        var nearestY =
            cy < topLeft[1]
                ? topLeft[1]
                : cy > bottomRight[1]
                  ? bottomRight[1]
                  : cy;
        var dx = nearestX - cx;
        var dy = nearestY - cy;
        return dx * dx + dy * dy <= circleR * circleR;
    }

    private function _hasPendingBacklog() as Boolean {
        for (var i = 0; i < _neededTiles.size(); i++) {
            var t = _neededTiles[i];
            var key = client.tileKeyFor(
                t[0] as Number,
                t[1] as Number,
                t[2] as Number,
                t[3] as Number
            );
            if (!_tiles.hasKey(key)) {
                return true;
            }
        }
        return false;
    }

    public function _onTileReceive(
        z as Number,
        x as Number,
        y as Number,
        tileSize as Number,
        bitmap as MapTileClient.MapBitmap?
    ) as Void {
        var key = client.tileKeyFor(z, x, y, tileSize);
        var stillNeeded =
            _neededKeys.hasKey(key) and Settings.showBackgroundMap;
        if (bitmap == null) {
            // An abandoned tile also arrives as null - only one something still needs is a failure worth retrying.
            if (stillNeeded) {
                _scheduleRetry();
            }
            return;
        }

        // Must resolve via get() - an unresolved BitmapReference isn't a strong reference and can be reclaimed.
        var resolved;
        if (bitmap instanceof Graphics.BitmapReference) {
            try {
                resolved = bitmap.get() as Graphics.BitmapType?;
            } catch (ex instanceof Lang.Exception) {
                resolved = null;
            }
        } else {
            resolved = bitmap as Graphics.BitmapType;
        }
        if (resolved == null) {
            if (stillNeeded) {
                _scheduleRetry();
            }
            return;
        }
        _nextRetryAtMs = null;
        _retryBackoffMs = INITIAL_RETRY_BACKOFF_MS;
        ApiStatus.setState(ApiStatus.map, true);
        if (!stillNeeded) {
            return;
        }

        var topLeftLatLon = Projection.tileToLatLon(x, y, z);
        var bottomRightLatLon = Projection.tileToLatLon(x + 1, y + 1, z);
        _tiles[key] = [
            resolved,
            x,
            y,
            z,
            tileSize,
            topLeftLatLon,
            bottomRightLatLon,
        ];
        _pruneStaleTilesCoveredBy(topLeftLatLon, bottomRightLatLon);
        WatchUi.requestUpdate();
    }

    private function _scheduleRetry() as Void {
        ApiStatus.setState(ApiStatus.map, false);
        _nextRetryAtMs = System.getTimer() + _retryBackoffMs;
        _retryBackoffMs *= 2;
        if (_retryBackoffMs > MAX_RETRY_BACKOFF_MS) {
            _retryBackoffMs = MAX_RETRY_BACKOFF_MS;
        }
        // Otherwise needsRefetch sees zero drift from the failed target and never retries while stationary.
        _requestedLat = null;
    }

    private function _latLonRectsOverlap(
        aTopLeft as [Float, Float],
        aBottomRight as [Float, Float],
        bTopLeft as [Float, Float],
        bBottomRight as [Float, Float]
    ) as Boolean {
        return (
            aBottomRight[0] < bTopLeft[0] and
            bBottomRight[0] < aTopLeft[0] and
            aTopLeft[1] < bBottomRight[1] and
            bTopLeft[1] < aBottomRight[1]
        );
    }

    // True if any stale placeholder overlaps this footprint - only areas with neither fresh nor stale tiles need "Loading...".
    private function _coveredByStaleTile(
        topLeftLatLon as [Float, Float],
        bottomRightLatLon as [Float, Float]
    ) as Boolean {
        for (var i = 0; i < _staleTiles.size(); i++) {
            var stale = _staleTiles[i];
            if (
                _latLonRectsOverlap(
                    topLeftLatLon,
                    bottomRightLatLon,
                    stale[5] as [Float, Float],
                    stale[6] as [Float, Float]
                )
            ) {
                return true;
            }
        }
        return false;
    }

    // Drops any stale tile the newly-arrived tile geographically overlaps - keeps peak memory close to one view's worth instead of both sets fully resident during the transition.
    private function _pruneStaleTilesCoveredBy(
        topLeftLatLon as [Float, Float],
        bottomRightLatLon as [Float, Float]
    ) as Void {
        if (_staleTiles.size() == 0) {
            return;
        }
        var kept = [] as Array<MapTile>;
        for (var i = 0; i < _staleTiles.size(); i++) {
            var stale = _staleTiles[i];
            if (
                !_latLonRectsOverlap(
                    topLeftLatLon,
                    bottomRightLatLon,
                    stale[5] as [Float, Float],
                    stale[6] as [Float, Float]
                )
            ) {
                kept.add(stale);
            }
        }
        _staleTiles = kept;

        var units = 0;
        for (var i = 0; i < kept.size(); i++) {
            units += (kept[i][4] as Number) == client.TILE_SIZE_HI ? 4 : 1;
        }
        var freshValues = _tiles.values();
        for (var i = 0; i < freshValues.size(); i++) {
            units +=
                (freshValues[i][4] as Number) == client.TILE_SIZE_HI ? 4 : 1;
        }
        if (units > STALE_HARD_CEILING_STD_UNITS) {
            _staleTiles = [] as Array<MapTile>;
        }
    }

    // Redrawn every frame, unthrottled - only the fetch itself is debounced.
    public function draw(
        dc as Dc,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        focusLat as Float,
        focusLon as Float
    ) as Void {
        for (var i = 0; i < _staleTiles.size(); i++) {
            _drawTile(
                dc,
                _staleTiles[i],
                cx,
                cy,
                radiusPx,
                radiusKm,
                focusLat,
                focusLon
            );
        }

        var keys = _tiles.keys();
        for (var i = 0; i < keys.size(); i++) {
            _drawTile(
                dc,
                _tiles[keys[i] as String],
                cx,
                cy,
                radiusPx,
                radiusKm,
                focusLat,
                focusLon
            );
        }

        dc.setColor(Palette.GRID_LABEL, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < _neededTiles.size(); i++) {
            var needed = _neededTiles[i];
            var nz = needed[0] as Number;
            var nx = needed[1] as Number;
            var ny = needed[2] as Number;
            var nSize = needed[3] as Number;
            var neededKey = client.tileKeyFor(nz, nx, ny, nSize);
            if (_tiles.hasKey(neededKey)) {
                continue;
            }
            var pendingTopLeftLatLon = Projection.tileToLatLon(nx, ny, nz);
            var pendingBottomRightLatLon = Projection.tileToLatLon(
                nx + 1,
                ny + 1,
                nz
            );
            if (
                _coveredByStaleTile(
                    pendingTopLeftLatLon,
                    pendingBottomRightLatLon
                )
            ) {
                continue;
            }
            var pendingTopLeft = Projection.toScreenF(
                focusLat,
                focusLon,
                pendingTopLeftLatLon[0],
                pendingTopLeftLatLon[1],
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            var pendingBottomRight = Projection.toScreenF(
                focusLat,
                focusLon,
                pendingBottomRightLatLon[0],
                pendingBottomRightLatLon[1],
                cx,
                cy,
                radiusPx,
                radiusKm
            );
            var midX = (pendingTopLeft[0] + pendingBottomRight[0]) / 2.0;
            var midY = (pendingTopLeft[1] + pendingBottomRight[1]) / 2.0;
            dc.drawText(
                midX.toNumber(),
                midY.toNumber(),
                _font,
                _loadingText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    // Each tile's own two corners, not one shared scale - Mercator tiles vary in real height by latitude.
    private function _drawTile(
        dc as Dc,
        tile as MapTile,
        cx as Number,
        cy as Number,
        radiusPx as Number,
        radiusKm as Float,
        focusLat as Float,
        focusLon as Float
    ) as Void {
        var bitmap = tile[0] as Graphics.BitmapType;
        var tileSize = tile[4] as Number;
        var topLeftLatLon = tile[5] as [Float, Float];
        var bottomRightLatLon = tile[6] as [Float, Float];
        var topLeft = Projection.toScreenF(
            focusLat,
            focusLon,
            topLeftLatLon[0],
            topLeftLatLon[1],
            cx,
            cy,
            radiusPx,
            radiusKm
        );
        var bottomRight = Projection.toScreenF(
            focusLat,
            focusLon,
            bottomRightLatLon[0],
            bottomRightLatLon[1],
            cx,
            cy,
            radiusPx,
            radiusKm
        );
        // Whole-pixel rounding avoids a per-tile AA seam at the shared edge, even though both tiles compute it float-identical.
        var left = Math.round(topLeft[0]);
        var top = Math.round(topLeft[1]);
        var right = Math.round(bottomRight[0]);
        var bottom = Math.round(bottomRight[1]);
        var scaleX = (right - left) / tileSize.toFloat();
        var scaleY = (bottom - top) / tileSize.toFloat();
        var xform = new Graphics.AffineTransform();
        xform.translate(left, top);
        xform.scale(scaleX, scaleY);
        dc.drawBitmap2(0, 0, bitmap, {
            :transform => xform,
            :filterMode => Graphics.FILTER_MODE_POINT,
        });
    }
}
