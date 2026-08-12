import Toybox.Lang;

module JsonUtil {
    // Excludes only the types with no .toNumber()/.toFloat() (Dictionary/Array/Boolean) - String is
    // kept, it has both. Shared by every client that has to trust a decoded JSON value before coercing it.
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
}
