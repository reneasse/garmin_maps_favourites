import Toybox.Lang;
using Toybox.Application.Properties;

//! Typed access to the Garmin Connect app settings with safe defaults.
//! Properties.getValue() throws if a key is missing (e.g. after a partial
//! update), so every read is guarded and falls back to the documented default.
(:background)
module Settings {

    //! Garmin lehnt Hintergrund-Intervalle unter fuenf Minuten rundheraus ab.
    const MIN_INTERVAL_MIN = 5;
    const MAX_INTERVAL_MIN = 720;

    var serviceUrl as String = "";
    var autoSync as Boolean = true;
    var syncIntervalMin as Number = 60;
    var maxFavourites as Number = 150;
    var allowBulkDelete as Boolean = false;

    (:background)
    function load() as Void {
        serviceUrl = normaliseUrl(stringOr("serviceUrl", ""));
        autoSync = booleanOr("autoSync", true);
        syncIntervalMin = clampNumber(
            numberOr("syncIntervalMin", 60), MIN_INTERVAL_MIN, MAX_INTERVAL_MIN);
        maxFavourites = clampNumber(numberOr("maxFavourites", 150), 1, 200);
        allowBulkDelete = booleanOr("allowBulkDelete", false);
    }

    //! Die URL wird als Praefix an "index.json" bzw. "l/<id>/<n>.json" gehaengt,
    //! deshalb muss sie genau einen Schraegstrich am Ende haben. Getrennt von
    //! load(), damit die Regel ohne Properties testbar bleibt.
    (:background)
    function normaliseUrl(url as String) as String {
        var s = url;
        while (s.length() > 0 && s.substring(0, 1).equals(" ")) {
            s = s.substring(1, s.length()) as String;
        }
        while (s.length() > 0 && s.substring(s.length() - 1, s.length()).equals(" ")) {
            s = s.substring(0, s.length() - 1) as String;
        }
        if (s.length() == 0) { return ""; }
        if (!s.substring(s.length() - 1, s.length()).equals("/")) { s = s + "/"; }
        return s;
    }

    (:background)
    function configured() as Boolean {
        return serviceUrl.length() >= 8;
    }

    (:background)
    function raw(key as String) as Object or Null {
        try {
            return Properties.getValue(key);
        } catch (e) {
            return null;
        }
    }

    (:background)
    function stringOr(key as String, fallback as String) as String {
        var v = raw(key);
        if (v instanceof String) { return v; }
        return fallback;
    }

    (:background)
    function numberOr(key as String, fallback as Number) as Number {
        var v = raw(key);
        if (v instanceof Number) { return v; }
        if (v instanceof Float) { return v.toNumber(); }
        return fallback;
    }

    (:background)
    function booleanOr(key as String, fallback as Boolean) as Boolean {
        var v = raw(key);
        if (v instanceof Boolean) { return v; }
        return fallback;
    }

    (:background)
    function clampNumber(v as Number, lo as Number, hi as Number) as Number {
        if (v < lo) { return lo; }
        if (v > hi) { return hi; }
        return v;
    }
}
