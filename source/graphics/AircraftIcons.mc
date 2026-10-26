import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

// Per-aircraft icon, emergency badge, selection reticle and vert-rate chevron, plus the declutter rects that match each.
class AircraftIcons {
    private const GROUNDED_DIM_FACTOR = 0.75;
    // A position this old hasn't actually moved across several poll cycles - likely a fringe-of-coverage ghost.
    private const STALE_POSITION_SEC = 15.0;
    private const STALE_DIM_FACTOR = 0.75;
    // Tied to source PNGs' 3px/unit rendering - on-screen icon size stays constant if that changes.
    private const ICON_BASE_SCALE = 0.226667;
    private const ICON_RECT_MARGIN = 2;
    // Shared clearance past the icon's own extent - both the reticle and vert-rate chevron use this, not separate radii.
    private const ICON_MARKER_CLEARANCE = 6;

    // Fixed corner offset, not centered on the icon - centered markers looked off-center against asymmetric icons.
    private const EMERGENCY_BADGE_R = 7;
    private const EMERGENCY_BADGE_MARGIN = 2;
    private const EMERGENCY_BADGE_EXTRA_CLEARANCE = 10;
    // Up-left at a fixed 315deg (theta=0 up, clockwise, like chevronCenter), so sin/cos are precomputed.
    private const EMERGENCY_BADGE_SIN = -0.70710678;
    private const EMERGENCY_BADGE_COS = 0.70710678;

    private const SELECTION_ARROW_LEN = 7.0;
    private const SELECTION_ARROW_WIDTH = 5.0;
    private const SELECTION_RECT_MARGIN = 2;

    private const VERT_RATE_THRESHOLD_FPM = 150.0;
    private const CHEVRON_ANGLE_CLIMB_DEG = 45.0;
    private const CHEVRON_ANGLE_DESCEND_DEG = 135.0;
    private const CHEVRON_RECT_HALF = 4;

    // hex -> [category, shapeKey, sizeScale, iconHalfExtent, sourceCategory, sourceTypeCode].
    typedef ClassifyEntry as [String, String, Float, Number, String?, String?];
    private var _classifyCache as Dictionary<String, ClassifyEntry> = {};
    // Loaded lazily via _bitmapForShape - loading every shape up front made app open noticeably slow.
    private var _bitmapCache as Dictionary<String, Graphics.BitmapType> = {};

    private const RESOURCE_IDS as Dictionary<String, ResourceId> =
        ({
            "a10" => Rez.Drawables.AircraftA10,
            "a225" => Rez.Drawables.AircraftA225,
            "a319" => Rez.Drawables.AircraftA319,
            "a320" => Rez.Drawables.AircraftA320,
            "a321" => Rez.Drawables.AircraftA321,
            "a332" => Rez.Drawables.AircraftA332,
            "a359" => Rez.Drawables.AircraftA359,
            "a380" => Rez.Drawables.AircraftA380,
            "a400" => Rez.Drawables.AircraftA400,
            "airliner" => Rez.Drawables.AircraftAirliner,
            "alpha_jet" => Rez.Drawables.AircraftAlphaJet,
            "apache" => Rez.Drawables.AircraftApache,
            "b1b_lancer" => Rez.Drawables.AircraftB1bLancer,
            "b52" => Rez.Drawables.AircraftB52,
            "b707" => Rez.Drawables.AircraftB707,
            "b737" => Rez.Drawables.AircraftB737,
            "b738" => Rez.Drawables.AircraftB738,
            "b739" => Rez.Drawables.AircraftB739,
            "bae_hawk" => Rez.Drawables.AircraftBaeHawk,
            "balloon" => Rez.Drawables.AircraftBalloon,
            "beluga" => Rez.Drawables.AircraftBeluga,
            "blackhawk" => Rez.Drawables.AircraftBlackhawk,
            "blimp" => Rez.Drawables.AircraftBlimp,
            "c130" => Rez.Drawables.AircraftC130,
            "c17" => Rez.Drawables.AircraftC17,
            "c2" => Rez.Drawables.AircraftC2,
            "c5" => Rez.Drawables.AircraftC5,
            "cessna" => Rez.Drawables.AircraftCessna,
            "chinook" => Rez.Drawables.AircraftChinook,
            "cirrus_sr22" => Rez.Drawables.AircraftCirrusSr22,
            "dauphin" => Rez.Drawables.AircraftDauphin,
            "e390" => Rez.Drawables.AircraftE390,
            "e3awacs" => Rez.Drawables.AircraftE3awacs,
            "e737" => Rez.Drawables.AircraftE737,
            "f18" => Rez.Drawables.AircraftF18,
            "f35" => Rez.Drawables.AircraftF35,
            "f5_tiger" => Rez.Drawables.AircraftF5Tiger,
            "gazelle" => Rez.Drawables.AircraftGazelle,
            "glider" => Rez.Drawables.AircraftGlider,
            "ground_emergency" => Rez.Drawables.AircraftGroundEmergency,
            "ground_service" => Rez.Drawables.AircraftGroundService,
            "ground_tower" => Rez.Drawables.AircraftGroundTower,
            "ground_unknown" => Rez.Drawables.AircraftGroundUnknown,
            "gyrocopter" => Rez.Drawables.AircraftGyrocopter,
            "heavy_2e" => Rez.Drawables.AircraftHeavy2e,
            "heavy_4e" => Rez.Drawables.AircraftHeavy4e,
            "helicopter" => Rez.Drawables.AircraftHelicopter,
            "hi_perf" => Rez.Drawables.AircraftHiPerf,
            "hunter" => Rez.Drawables.AircraftHunter,
            "il_62" => Rez.Drawables.AircraftIl62,
            "jet_nonswept" => Rez.Drawables.AircraftJetNonswept,
            "jet_swept" => Rez.Drawables.AircraftJetSwept,
            "l159" => Rez.Drawables.AircraftL159,
            "lancaster" => Rez.Drawables.AircraftLancaster,
            "m326" => Rez.Drawables.AircraftM326,
            "md11" => Rez.Drawables.AircraftMd11,
            "md_a4" => Rez.Drawables.AircraftMdA4,
            "md_f15" => Rez.Drawables.AircraftMdF15,
            "mil24" => Rez.Drawables.AircraftMil24,
            "mirage" => Rez.Drawables.AircraftMirage,
            "miragef1" => Rez.Drawables.AircraftMiragef1,
            "p3_orion" => Rez.Drawables.AircraftP3Orion,
            "p8" => Rez.Drawables.AircraftP8,
            "pa24" => Rez.Drawables.AircraftPa24,
            "para" => Rez.Drawables.AircraftPara,
            "puma" => Rez.Drawables.AircraftPuma,
            "rafale" => Rez.Drawables.AircraftRafale,
            "rutan_veze" => Rez.Drawables.AircraftRutanVeze,
            "s61" => Rez.Drawables.AircraftS61,
            "sb39" => Rez.Drawables.AircraftSb39,
            "strato" => Rez.Drawables.AircraftStrato,
            "super_guppy" => Rez.Drawables.AircraftSuperGuppy,
            "t38" => Rez.Drawables.AircraftT38,
            "tiger" => Rez.Drawables.AircraftTiger,
            "tornado" => Rez.Drawables.AircraftTornado,
            "twin_large" => Rez.Drawables.AircraftTwinLarge,
            "typhoon" => Rez.Drawables.AircraftTyphoon,
            "u2" => Rez.Drawables.AircraftU2,
            "uav" => Rez.Drawables.AircraftUav,
            "unknown" => Rez.Drawables.AircraftUnknown,
            "v22_slow" => Rez.Drawables.AircraftV22Slow,
            "verhees" => Rez.Drawables.AircraftVerhees,
            "wb57" => Rez.Drawables.AircraftWb57,
        }) as Dictionary<String, ResourceId>;

    public function initialize() {}

    // Classification depends only on category and type code, so an entry survives polls until either changes.
    public function pruneClassifyCache(
        byHex as Dictionary<String, Aircraft>
    ) as Void {
        var keys = _classifyCache.keys();
        for (var i = 0; i < keys.size(); i++) {
            var hex = keys[i] as String;
            var ac = byHex[hex];
            var entry = _classifyCache[hex] as ClassifyEntry;
            if (
                ac == null ||
                !_sameString(entry[4], (ac as Aircraft).category) ||
                !_sameString(entry[5], (ac as Aircraft).typeCode)
            ) {
                _classifyCache.remove(hex);
            }
        }
    }

    private function _sameString(a as String?, b as String?) as Boolean {
        return a == null ? b == null : b != null && (a as String).equals(b);
    }

    private function _classify(ac as Aircraft) as ClassifyEntry {
        var cached = _classifyCache[ac.hex];
        if (cached != null) {
            return cached as ClassifyEntry;
        }
        var cat = AircraftClassifier.effectiveCategory(ac);
        var shape = AircraftClassifier.shapeKeyForCategory(ac, cat);
        var scale = AircraftClassifier.sizeScaleForCategory(cat);
        var halfExtent = AircraftClassifier.iconHalfExtentForShape(
            shape,
            ICON_BASE_SCALE * scale
        );
        var result =
            [cat, shape, scale, halfExtent, ac.category, ac.typeCode] as
            ClassifyEntry;
        _classifyCache[ac.hex] = result;
        return result;
    }

    public function sizeScale(ac as Aircraft) as Float {
        return _classify(ac)[2];
    }

    private function _halfExtent(ac as Aircraft) as Number {
        return _classify(ac)[3];
    }

    public function colorFor(ac as Aircraft) as Number {
        if (Settings.singleColorMode) {
            return Palette.AIRCRAFT_DEFAULT;
        }
        if (ac.military) {
            return Palette.MILITARY;
        }
        if (ac.isGroundVehicle() or ac.isObstacle()) {
            return Palette.GROUND;
        }
        var cat = _classify(ac)[0];
        if (cat.equals("A7")) {
            return Palette.HELICOPTER;
        }
        if (cat.equals("A1")) {
            return Palette.AIRCRAFT_LIGHT;
        }
        if (cat.equals("A3") || cat.equals("A4") || cat.equals("A5")) {
            return Palette.AIRCRAFT_HEAVY;
        }
        if (cat.equals("A6")) {
            return Palette.AIRCRAFT_FAST;
        }
        return Palette.AIRCRAFT_DEFAULT;
    }

    public function iconRect(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number, Number] {
        var half = _halfExtent(ac) + ICON_RECT_MARGIN;
        return (
            [x - half, y - half, x + half, y + half] as
            [Number, Number, Number, Number]
        );
    }

    public function drawIcon(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var color = colorFor(ac);
        if (Settings.dimGroundedAircraft && ac.onGround) {
            color = DrawUtils.dimColor(color, GROUNDED_DIM_FACTOR);
        }
        var age = ac.positionAgeSec;
        if (
            Settings.dimStaleAircraft &&
            age != null &&
            (age as Float) >= STALE_POSITION_SEC
        ) {
            color = DrawUtils.dimColor(color, STALE_DIM_FACTOR);
        }

        var shape = _classify(ac)[1];
        // Track first so the nose follows the trail and glide; heading covers stationary aircraft, where the feed omits track.
        var rotation = ac.track != null ? ac.track : ac.heading;
        var theta =
            rotation != null && AircraftClassifier.shapeRotates(shape)
                ? Math.toRadians(rotation)
                : 0.0;

        var scale = ICON_BASE_SCALE * sizeScale(ac);
        var pivot = AircraftClassifier.ICON_PIVOT[shape];
        var halfW = pivot != null ? (pivot as [Float, Float])[0] : 30.0;
        var halfH = pivot != null ? (pivot as [Float, Float])[1] : 30.0;

        var tf = new Graphics.AffineTransform();
        tf.translate(x.toFloat(), y.toFloat());
        tf.rotate(theta);
        tf.scale(scale, scale);
        tf.translate(-halfW, -halfH);

        dc.drawBitmap2(0, 0, _bitmapForShape(shape), {
            :transform => tf,
            :tintColor => color,
            // Default (nearest-neighbor) is jagged at this rotation/downscale ratio - bilinear smooths it.
            :filterMode => Graphics.FILTER_MODE_BILINEAR,
        });
    }

    private function _bitmapForShape(shape as String) as Graphics.BitmapType {
        var cached = _bitmapCache[shape];
        if (cached != null) {
            return cached as Graphics.BitmapType;
        }
        var bmp =
            WatchUi.loadResource(RESOURCE_IDS[shape] as ResourceId) as
            Graphics.BitmapType;
        _bitmapCache[shape] = bmp;
        return bmp;
    }

    private function _emergencyBadgeCenter(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number] {
        var r = (
            _halfExtent(ac) +
            ICON_MARKER_CLEARANCE +
            EMERGENCY_BADGE_EXTRA_CLEARANCE
        ).toFloat();
        return (
            [
                NumUtils.round(x + r * EMERGENCY_BADGE_SIN),
                NumUtils.round(y - r * EMERGENCY_BADGE_COS),
            ] as [Number, Number]
        );
    }

    public function drawEmergencyBadge(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var c = _emergencyBadgeCenter(x, y, ac);
        DrawUtils.drawWarningIcon(
            dc,
            c[0],
            c[1],
            EMERGENCY_BADGE_R,
            Palette.EMERGENCY
        );
    }

    public function emergencyBadgeRect(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number, Number] {
        var c = _emergencyBadgeCenter(x, y, ac);
        var r = EMERGENCY_BADGE_R + EMERGENCY_BADGE_MARGIN;
        return (
            [c[0] - r, c[1] - r, c[0] + r, c[1] + r] as
            [Number, Number, Number, Number]
        );
    }

    // Shared by drawSelectionReticle and selectionReticleRect - [tipY, baseY, halfW].
    private function _selectionReticleGeometry(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number] {
        var scale = sizeScale(ac);
        var tipY = y - (_halfExtent(ac) + ICON_MARKER_CLEARANCE);
        var baseY = tipY - (SELECTION_ARROW_LEN * scale).toNumber();
        var halfW = (SELECTION_ARROW_WIDTH * scale).toNumber();
        return [tipY, baseY, halfW] as [Number, Number, Number];
    }

    public function drawSelectionReticle(
        dc as Dc,
        x as Number,
        y as Number,
        ac as Aircraft
    ) as Void {
        var geom = _selectionReticleGeometry(x, y, ac);
        var tipY = geom[0];
        var baseY = geom[1];
        var halfW = geom[2];
        dc.setColor(Palette.SELECTED, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([
            [x, tipY],
            [x - halfW, baseY],
            [x + halfW, baseY],
        ]);
    }

    public function selectionReticleRect(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number, Number, Number] {
        var geom = _selectionReticleGeometry(x, y, ac);
        var tipY = geom[0];
        var baseY = geom[1];
        var halfW = geom[2];
        return (
            [
                x - halfW - SELECTION_RECT_MARGIN,
                baseY - SELECTION_RECT_MARGIN,
                x + halfW + SELECTION_RECT_MARGIN,
                tipY + SELECTION_RECT_MARGIN,
            ] as [Number, Number, Number, Number]
        );
    }

    // Shared by drawVertRateChevron and chevronRect, so the declutter rect matches where it actually draws.
    public function chevronCenter(
        x as Number,
        y as Number,
        ac as Aircraft
    ) as [Number, Number]? {
        var rate = ac.vertRate;
        if (rate == null or (rate as Float).abs() < VERT_RATE_THRESHOLD_FPM) {
            return null;
        }
        // Angle+radius past the icon's extent, not a flat offset, so it clears small icons too.
        var r = (_halfExtent(ac) + ICON_MARKER_CLEARANCE).toFloat();
        var theta = Math.toRadians(
            (rate as Float) > 0
                ? CHEVRON_ANGLE_CLIMB_DEG
                : CHEVRON_ANGLE_DESCEND_DEG
        );
        return (
            [
                x + NumUtils.round(r * Math.sin(theta)),
                y - NumUtils.round(r * Math.cos(theta)),
            ] as [Number, Number]
        );
    }

    public function drawVertRateChevron(
        dc as Dc,
        center as [Number, Number],
        ac as Aircraft
    ) as Void {
        var cx = center[0];
        var cy = center[1];
        var dir = (ac.vertRate as Float) > 0 ? 1 : -1;
        dc.setColor(colorFor(ac), Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 3, cy + dir * 3, cx, cy);
        dc.drawLine(cx, cy, cx + 3, cy + dir * 3);
    }

    public function chevronRect(
        center as [Number, Number]
    ) as [Number, Number, Number, Number] {
        var cx = center[0];
        var cy = center[1];
        return (
            [
                cx - CHEVRON_RECT_HALF,
                cy - CHEVRON_RECT_HALF,
                cx + CHEVRON_RECT_HALF,
                cy + CHEVRON_RECT_HALF,
            ] as [Number, Number, Number, Number]
        );
    }
}
