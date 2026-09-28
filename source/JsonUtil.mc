import Toybox.Lang;

module JsonUtil {
    // String passes - it has toNumber()/toFloat() too, so callers must still handle a null conversion.
    function isNumeric(v) as Boolean {
        return (
            v != null and
            !(
                v instanceof Lang.Dictionary or
                v instanceof Lang.Array or
                v instanceof Lang.Boolean
            )
        );
    }

    function toFloatOrNull(v) as Float? {
        return isNumeric(v) ? v.toFloat() : null;
    }

    function toNumberOrNull(v) as Number? {
        return isNumeric(v) ? v.toNumber() : null;
    }
}
