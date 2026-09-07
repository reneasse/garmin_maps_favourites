import Toybox.Lang;

//! Auswertung des JSON-Contracts, das der Scraper auf GitHub Pages ablegt.
//!
//! Katalog  <base>index.json        {"v":1,"t":epoch,"l":[{"i","n","c","h","p"}]}
//! Seite    <base>l/<id>/<n>.json   {"i","h","p","n","e":[[name,lat,lon]]}
//!
//! Alles hier ist reine Funktion ohne Storage- oder Netzzugriff, damit der
//! Umgang mit verstuemmelten Antworten in Unit-Tests festgenagelt werden kann.
//! Jedes Feld wird einzeln geprueft: eine halb gelesene Antwort darf nie als
//! gueltige, leere Liste durchgehen - daraus wuerden Loeschungen.
(:background)
module Feed {

    //! Schema-Version, die diese App versteht.
    const VERSION = 1;

    //! Katalogeintrag als [id, name, count, hash, pages].
    const C_ID = 0;
    const C_NAME = 1;
    const C_COUNT = 2;
    const C_HASH = 3;
    const C_PAGES = 4;

    //! Ortseintrag als [name, lat, lon].
    const E_NAME = 0;
    const E_LAT = 1;
    const E_LON = 2;

    //! -> Array von [id, name, count, hash, pages], oder null bei Unfug.
    (:background)
    function parseCatalog(raw as Object or Null) as Array or Null {
        if (!(raw instanceof Dictionary)) { return null; }
        var v = raw["v"];
        if (!(v instanceof Number) || v != VERSION) { return null; }
        var lists = raw["l"];
        if (!(lists instanceof Array)) { return null; }

        var out = [] as Array;
        for (var i = 0; i < lists.size(); i++) {
            var entry = parseCatalogEntry(lists[i]);
            if (entry != null) { out.add(entry); }
        }
        return out;
    }

    (:background)
    function parseCatalogEntry(raw as Object or Null) as Array or Null {
        if (!(raw instanceof Dictionary)) { return null; }
        var id = raw["i"];
        var name = raw["n"];
        var count = raw["c"];
        var hash = raw["h"];
        var pages = raw["p"];
        if (!(id instanceof String) || id.length() == 0) { return null; }
        if (!(name instanceof String) || name.length() == 0) { return null; }
        if (!(count instanceof Number) || count < 0) { return null; }
        if (!(hash instanceof String) || hash.length() == 0) { return null; }
        if (!(pages instanceof Number) || pages < 0) { return null; }
        return [id, name, count, hash, pages] as Array;
    }

    //! Sucht einen Katalogeintrag. Null, wenn die Liste verschwunden ist.
    (:background)
    function findList(catalog as Array or Null, id as String) as Array or Null {
        if (catalog == null) { return null; }
        for (var i = 0; i < catalog.size(); i++) {
            var entry = catalog[i];
            if (entry instanceof Array && entry.size() > C_PAGES) {
                var cid = entry[C_ID];
                if (cid instanceof String && cid.equals(id)) { return entry; }
            }
        }
        return null;
    }

    //! -> Array von [name, lat, lon], oder null.
    //!
    //! Id und Hash muessen zu der Liste passen, die gerade geholt wird. Laeuft
    //! der Backend-Build mitten in einem Sync durch, kaeme sonst Seite 0 vom
    //! alten und Seite 1 vom neuen Stand - und der Abgleich haette Luecken.
    (:background)
    function parsePage(raw as Object or Null, id as String, hash as String) as Array or Null {
        if (!(raw instanceof Dictionary)) { return null; }
        var pid = raw["i"];
        var phash = raw["h"];
        if (!(pid instanceof String) || !pid.equals(id)) { return null; }
        if (!(phash instanceof String) || !phash.equals(hash)) { return null; }
        var entries = raw["e"];
        if (!(entries instanceof Array)) { return null; }

        var out = [] as Array;
        for (var i = 0; i < entries.size(); i++) {
            var place = parsePlace(entries[i]);
            if (place != null) { out.add(place); }
        }
        return out;
    }

    (:background)
    function parsePlace(raw as Object or Null) as Array or Null {
        if (!(raw instanceof Array) || raw.size() < 3) { return null; }
        var name = raw[E_NAME];
        if (!(name instanceof String) || name.length() == 0) { return null; }
        var lat = Util.toFloat(raw[E_LAT]);
        var lon = Util.toFloat(raw[E_LON]);
        if (!Util.validCoord(lat, lon)) { return null; }
        return [name, lat, lon] as Array;
    }

    //! Die Namen aus einer geparsten Seitenliste.
    (:background)
    function names(places as Array) as Array<String> {
        var out = [] as Array<String>;
        for (var i = 0; i < places.size(); i++) {
            var p = places[i];
            if (p instanceof Array && p.size() > E_NAME) {
                var n = p[E_NAME];
                if (n instanceof String) { out.add(n); }
            }
        }
        return out;
    }
}
