import Toybox.Lang;
using Toybox.PersistedContent;
using Toybox.Position;

//! Der einzige Zugang zur Standortliste des Geraets.
//!
//! PersistedContent.getAppWaypoints() liefert ausschliesslich Wegpunkte, die
//! diese App angelegt hat, und remove() wirft, sobald man fremden Content
//! anfasst. Favoriten, die der Nutzer selbst gesetzt hat, sind damit von
//! vornherein ausser Reichweite - das ist die wichtigste Eigenschaft dieses
//! Moduls und der Grund, warum der Abgleich ueberhaupt loeschen darf.
(:background)
module WaypointWriter {

    //! Aeltere Firmware kennt getAppWaypoints nicht; ohne sie waere Loeschen
    //! unmoeglich und die App wuerde nur noch Wegpunkte anhaeufen.
    (:background)
    function available() as Boolean {
        if (!(Toybox has :PersistedContent)) { return false; }
        if (!(PersistedContent has :getAppWaypoints)) { return false; }
        if (!(PersistedContent has :saveWaypoint)) { return false; }
        return true;
    }

    //! Namen aller Wegpunkte, die dieser App gehoeren.
    (:background)
    function presentNames() as Array<String> {
        var out = [] as Array<String>;
        if (!available()) { return out; }
        try {
            var it = PersistedContent.getAppWaypoints();
            for (var wp = it.next(); wp != null; wp = it.next()) {
                out.add(wp.getName());
            }
        } catch (e) {
            // Ein abgebrochener Durchlauf liefert eben nur einen Teil; der
            // Aufrufer behandelt das wie einen leeren Ist-Stand.
        }
        return out;
    }

    (:background)
    function add(name as String, lat as Float, lon as Float) as Boolean {
        if (!available()) { return false; }
        try {
            var loc = new Position.Location({
                :latitude => lat,
                :longitude => lon,
                :format => :degrees
            });
            PersistedContent.saveWaypoint(loc, { :name => name });
            return true;
        } catch (e) {
            return false;
        }
    }

    //! Entfernt alle App-Wegpunkte, deren Name in `names` steht und nicht in
    //! `keep` - `keep` sind die Namen, die andere Listen noch beanspruchen.
    //!
    //! Erst sammeln, dann loeschen: waehrend eines laufenden Iterators zu
    //! entfernen ist nirgends zugesichert.
    (:background)
    function removeNames(names as Array<String>, keep as Array<String>) as Number {
        if (!available() || names.size() == 0) { return 0; }
        var hits = [] as Array<PersistedContent.Waypoint>;
        try {
            var it = PersistedContent.getAppWaypoints();
            for (var wp = it.next(); wp != null; wp = it.next()) {
                var name = wp.getName();
                if (!Util.contains(names, name)) { continue; }
                if (Util.contains(keep, name)) { continue; }
                hits.add(wp as PersistedContent.Waypoint);
            }
        } catch (e) {
            return 0;
        }
        return removeAllOf(hits);
    }

    //! Entfernt jeden Wegpunkt, den diese App angelegt hat.
    (:background)
    function removeAll() as Number {
        if (!available()) { return 0; }
        var hits = [] as Array<PersistedContent.Waypoint>;
        try {
            var it = PersistedContent.getAppWaypoints();
            for (var wp = it.next(); wp != null; wp = it.next()) {
                hits.add(wp as PersistedContent.Waypoint);
            }
        } catch (e) {
            return 0;
        }
        return removeAllOf(hits);
    }

    (:background)
    function removeAllOf(hits as Array<PersistedContent.Waypoint>) as Number {
        var removed = 0;
        for (var i = 0; i < hits.size(); i++) {
            try {
                hits[i].remove();
                removed++;
            } catch (e) {
                // Gehoert der App nicht mehr oder ist schon weg - beides ist
                // kein Grund, den Rest stehen zu lassen.
            }
        }
        return removed;
    }
}
