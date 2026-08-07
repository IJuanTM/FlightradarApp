import Toybox.Lang;
import Toybox.WatchUi;

// Shared by OpenSkyClient/MapClient - each loads a different named section of the same gitignored Credentials.json resource.
module CredentialsUtil {
    // Null if the resource, section, or any requested field is missing/wrong-typed.
    function loadStrings(
        section as String,
        keys as Array<String>
    ) as Array<String>? {
        var creds =
            WatchUi.loadResource(Rez.JsonData.Credentials) as Dictionary;
        var sec = creds[section];
        if (!(sec instanceof Lang.Dictionary)) {
            return null;
        }
        var result = [] as Array<String>;
        for (var i = 0; i < keys.size(); i++) {
            var v = (sec as Dictionary)[keys[i]];
            if (!(v instanceof Lang.String)) {
                return null;
            }
            result.add(v as String);
        }
        return result;
    }
}
