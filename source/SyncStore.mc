import Toybox.Lang;
using Toybox.Application.Storage;
using Toybox.Time;

//! Gemeinsamer Ablageplatz fuer Vordergrund und Hintergrunddienst.
//!
//! Schema (Storage erlaubt nur einfache Typen, Werte hoechstens 8 kB):
//!   "sel"      Array<String>  - ausgewaehlte Listen-Ids
//!   "cat"      Array          - letzter Katalog, [id, name, count, hash, pages]
//!   "st"       Dictionary     - {"t" Zeit, "e" Code, "n" Anzahl, "b" Blockade}
//!   "idx"      Array<String>  - Listen, zu denen ein Zustand existiert
//!   "w"+id     Dictionary     - {"h" Hash, "n" Array<String> geschriebene Namen}
//!
//! Bewusst ein eigener Key je Liste: der Hintergrundprozess hat 32 kB Heap und
//! darf nie gezwungen sein, alle ~200 Namen auf einmal zu laden. Nebenbei bleibt
//! jeder einzelne Wert weit unter der 8-kB-Grenze von Storage.
//!
//! Der gespeicherte Hash ist die Abkuerzung: stimmt er mit dem Katalog ueberein,
//! wird die Liste gar nicht erst geladen. Ein leerer Hash heisst "unfertig" und
//! erzwingt beim naechsten Lauf einen frischen Abgleich.
(:background)
module SyncStore {

    const KEY_SELECTION = "sel";
    const KEY_CATALOG = "cat";
    const KEY_STATUS = "st";
    const KEY_INDEX = "idx";
    const PREFIX_LIST = "w";

    //! Eigene Zustandscodes bleiben unter 100. Alles ab 100 ist ein woertlicher
    //! HTTP-Status, alles Negative ein Connect-IQ-Transportfehler (z. B. -402,
    //! Antwort zu gross). So bleibt der Rohwert in der Anzeige nachvollziehbar.
    const STAT_IDLE = 0;
    const STAT_OK = 1;
    const STAT_RUNNING = 2;
    const STAT_NO_URL = 3;
    const STAT_NO_CONN = 4;
    const STAT_NO_LISTS = 5;
    const STAT_BAD_DATA = 6;
    const STAT_EMPTY = 7;
    const STAT_TOO_MANY = 8;
    const STAT_BULK = 9;
    const STAT_PARTIAL = 10;
    const STAT_NO_API = 11;

    // -- Auswahl ---------------------------------------------------------------

    (:background)
    function selection() as Array<String> {
        return stringArray(get(KEY_SELECTION));
    }

    function saveSelection(ids as Array<String>) as Void {
        set(KEY_SELECTION, ids);
    }

    // -- Katalog ---------------------------------------------------------------

    function catalog() as Array or Null {
        var raw = get(KEY_CATALOG);
        if (!(raw instanceof Array)) { return null; }
        return raw;
    }

    (:background)
    function saveCatalog(entries as Array) as Void {
        set(KEY_CATALOG, entries);
    }

    // -- Status ----------------------------------------------------------------

    (:background)
    function saveStatus(code as Number, count as Number, blocked as Number) as Void {
        set(KEY_STATUS, {
            "t" => Time.now().value(),
            "e" => code,
            "n" => count,
            "b" => blocked
        });
    }

    function status() as Dictionary {
        var raw = get(KEY_STATUS);
        if (!(raw instanceof Dictionary)) {
            return { "t" => 0, "e" => STAT_IDLE, "n" => 0, "b" => 0 };
        }
        return {
            "t" => numberOr(raw["t"], 0),
            "e" => numberOr(raw["e"], STAT_IDLE),
            "n" => numberOr(raw["n"], 0),
            "b" => numberOr(raw["b"], 0)
        };
    }

    // -- Zustand je Liste ------------------------------------------------------

    (:background)
    function listKey(id as String) as String {
        return PREFIX_LIST + id;
    }

    (:background)
    function listHash(id as String) as String {
        var raw = get(listKey(id));
        if (!(raw instanceof Dictionary)) { return ""; }
        var h = raw["h"];
        if (!(h instanceof String)) { return ""; }
        return h;
    }

    (:background)
    function listNames(id as String) as Array<String> {
        var raw = get(listKey(id));
        if (!(raw instanceof Dictionary)) { return [] as Array<String>; }
        return stringArray(raw["n"]);
    }

    //! `hash` leer lassen, wenn der Abgleich unvollstaendig blieb - dann holt
    //! der naechste Lauf die Liste erneut und macht weiter, wo er aufhoerte.
    (:background)
    function saveList(id as String, hash as String, names as Array<String>) as Void {
        set(listKey(id), { "h" => hash, "n" => names });
        rememberId(id);
    }

    (:background)
    function dropList(id as String) as Void {
        try {
            Storage.deleteValue(listKey(id));
        } catch (e) {
            // Nicht vorhanden ist genauso gut wie geloescht.
        }
        var ids = knownIds();
        var kept = [] as Array<String>;
        for (var i = 0; i < ids.size(); i++) {
            if (!ids[i].equals(id)) { kept.add(ids[i]); }
        }
        set(KEY_INDEX, kept);
    }

    (:background)
    function knownIds() as Array<String> {
        return stringArray(get(KEY_INDEX));
    }

    (:background)
    function rememberId(id as String) as Void {
        var ids = knownIds();
        if (Util.contains(ids, id)) { return; }
        ids.add(id);
        set(KEY_INDEX, ids);
    }

    //! Alle Namen, die andere Listen fuer sich beanspruchen.
    //!
    //! Ohne das wuerde ein Ort, der in zwei Listen steht und aus einer davon
    //! verschwindet, vom Geraet fliegen - obwohl die zweite Liste ihn noch will.
    (:background)
    function namesExcept(id as String) as Array<String> {
        var ids = knownIds();
        var out = [] as Array<String>;
        for (var i = 0; i < ids.size(); i++) {
            if (ids[i].equals(id)) { continue; }
            var names = listNames(ids[i]);
            for (var j = 0; j < names.size(); j++) {
                if (!Util.contains(out, names[j])) { out.add(names[j]); }
            }
        }
        return out;
    }

    //! Alle Namen, die diese App aktuell auf dem Geraet haben will.
    function allKnownNames() as Array<String> {
        var ids = knownIds();
        var out = [] as Array<String>;
        for (var i = 0; i < ids.size(); i++) {
            var names = listNames(ids[i]);
            for (var j = 0; j < names.size(); j++) {
                if (!Util.contains(out, names[j])) { out.add(names[j]); }
            }
        }
        return out;
    }

    //! Zaehlt, was die App laut eigenem Zustand geschrieben hat.
    function syncedCount() as Number {
        return allKnownNames().size();
    }

    //! Setzt den gesamten Sync-Zustand zurueck, ohne die Auswahl anzutasten.
    function forgetAll() as Void {
        var ids = knownIds();
        for (var i = 0; i < ids.size(); i++) {
            try {
                Storage.deleteValue(listKey(ids[i]));
            } catch (e) {
            }
        }
        set(KEY_INDEX, [] as Array<String>);
    }

    // -- Zugriff ---------------------------------------------------------------

    (:background)
    function get(key as String) as Object or Null {
        try {
            return Storage.getValue(key);
        } catch (e) {
            return null;
        }
    }

    (:background)
    function set(key as String, value as Object or Null) as Void {
        try {
            Storage.setValue(key, value);
        } catch (e) {
            // Volles oder gesperrtes Storage darf den Sync nicht abbrechen; der
            // naechste Lauf sieht dann nur einen aelteren Zustand.
        }
    }

    //! Storage liefert alles als Object zurueck - hier wird daraus wieder eine
    //! saubere Namensliste, ohne Fremdkoerper.
    (:background)
    function stringArray(raw as Object or Null) as Array<String> {
        var out = [] as Array<String>;
        if (!(raw instanceof Array)) { return out; }
        for (var i = 0; i < raw.size(); i++) {
            var v = raw[i];
            if (v instanceof String) { out.add(v); }
        }
        return out;
    }

    (:background)
    function numberOr(v as Object or Null, fallback as Number) as Number {
        if (v instanceof Number) { return v; }
        return fallback;
    }
}
