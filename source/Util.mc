import Toybox.Lang;

//! Small helpers shared by the sync engine, the store and the views.
(:background)
module Util {

    //! Enthaelt das Array diesen Namen?
    //!
    //! Bewusst nicht Array.indexOf: das vergleicht Objekte, und bei Strings ist
    //! nur String.equals() als Wertvergleich zugesichert. Der ganze Abgleich
    //! haengt an dieser Frage - hier wird nicht geraten.
    (:background)
    function contains(list as Array<String>, name as String) as Boolean {
        for (var i = 0; i < list.size(); i++) {
            var v = list[i];
            if (v instanceof String && v.equals(name)) { return true; }
        }
        return false;
    }

    //! Alle Eintraege aus `a`, die in `b` fehlen.
    (:background)
    function difference(a as Array<String>, b as Array<String>) as Array<String> {
        var out = [] as Array<String>;
        for (var i = 0; i < a.size(); i++) {
            var v = a[i];
            if (v instanceof String && !contains(b, v)) { out.add(v); }
        }
        return out;
    }

    //! Alle Eintraege aus `a`, die auch in `b` stehen.
    (:background)
    function intersection(a as Array<String>, b as Array<String>) as Array<String> {
        var out = [] as Array<String>;
        for (var i = 0; i < a.size(); i++) {
            var v = a[i];
            if (v instanceof String && contains(b, v)) { out.add(v); }
        }
        return out;
    }

    //! Coerce whatever the JSON parser produced into a Float.
    (:background)
    function toFloat(v as Object or Null) as Float {
        if (v instanceof Float) { return v; }
        if (v instanceof Number) { return v.toFloat(); }
        if (v instanceof Double) { return v.toFloat(); }
        return 0.0;
    }

    //! Nur echte, endliche Koordinaten duerfen ins Geraet. Ein 0/0 aus einem
    //! kaputten Parser wuerde sonst als Favorit im Golf von Guinea landen.
    (:background)
    function validCoord(lat as Float, lon as Float) as Boolean {
        if (lat < -90.0 || lat > 90.0) { return false; }
        if (lon < -180.0 || lon > 180.0) { return false; }
        if (lat == 0.0 && lon == 0.0) { return false; }
        return true;
    }

    (:background)
    function pad2(v as Number) as String {
        if (v < 10) { return "0" + v.toString(); }
        return v.toString();
    }

    //! Sekunden -> "3 min", "2 h", "5 d". Null, wenn es nichts zu zeigen gibt.
    (:background)
    function formatAge(seconds as Number) as String {
        if (seconds < 60) { return seconds.toString() + " s"; }
        var minutes = seconds / 60;
        if (minutes < 60) { return minutes.toString() + " min"; }
        var hours = minutes / 60;
        if (hours < 48) { return hours.toString() + " h"; }
        return (hours / 24).toString() + " d";
    }
}
