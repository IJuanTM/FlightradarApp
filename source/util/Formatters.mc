import Toybox.Lang;

module Formatters {
    function km(km as Float) as String {
        var whole = NumUtils.round(km);
        if (km >= 10.0 || (km - whole).abs() < 0.05) {
            return whole.toString() + "km";
        }
        return km.format("%.1f") + "km";
    }

    function altitude(altFt as Number) as String {
        if (Settings.useMetricUnits) {
            return NumUtils.round(altFt.toFloat() * 0.3048).toString() + "m";
        }
        return altFt.toString() + "ft";
    }

    function speedKt(kt as Number) as String {
        if (Settings.useMetricUnits) {
            return NumUtils.round(kt.toFloat() * 1.852).toString() + "km/h";
        }
        return kt.toString() + "kt";
    }

    // Caller adds the "+" for a climb; a descent keeps its own "-".
    function vertRate(fpm as Number) as String {
        if (Settings.useMetricUnits) {
            return NumUtils.round(fpm.toFloat() * 0.3048).toString() + "m/min";
        }
        return fpm.toString() + "fpm";
    }

    function lat(lat as Float, precise as Boolean) as String {
        var s = precise ? lat.abs().format("%.4f") : lat.abs().format("%.2f");
        return s + (lat >= 0 ? "N" : "S");
    }

    function lon(lon as Float, precise as Boolean) as String {
        var s = precise ? lon.abs().format("%.4f") : lon.abs().format("%.2f");
        return s + (lon >= 0 ? "E" : "W");
    }
}
