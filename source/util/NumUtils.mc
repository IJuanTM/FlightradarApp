import Toybox.Lang;

module NumUtils {
    function round(v as Float) as Number {
        return (v + (v >= 0 ? 0.5 : -0.5)).toNumber();
    }

    function roundHeading(v as Float) as Number {
        return ((round(v) % 360) + 360) % 360;
    }
}
