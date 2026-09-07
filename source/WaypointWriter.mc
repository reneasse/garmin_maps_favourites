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

    //! Der Ortsspeicher schneidet laengere Namen wortlos ab. Fuenfzehn Zeichen
    //! sind auf Edge 540, 840, 1040 und 1050 nachgemessen; bis dahin kommt jeder
    //! Name unveraendert zurueck - samt Umlauten, Akzenten und Leerzeichen am
    //! Ende. Darueber hinaus nicht, und daran haengt der ganze Abgleich.
    const NAME_LIMIT = 15;

    //! Aeltere Firmware kennt getAppWaypoints nicht; ohne sie waere Loeschen
    //! unmoeglich und die App wuerde nur noch Wegpunkte anhaeufen.
    (:background)
    function available() as Boolean {
        if (!(Toybox has :PersistedContent)) { return false; }
        if (!(PersistedContent has :getAppWaypoints)) { return false; }
        if (!(PersistedContent has :saveWaypoint)) { return false; }
        return true;
    }

    //! Der Name, unter dem das Geraet einen Ort fuehren wird.
    //!
    //! Der Abgleich vergleicht Soll und Ist ausschliesslich ueber den Namen.
    //! Schreibt man einen zu langen, kommt er gekuerzt zurueck, kein einziger
    //! Wegpunkt findet sich wieder - die App meldet "teilweise uebertragen",
    //! merkt sich nichts, und die Aufraeumrunde haelt alles gerade Geschriebene
    //! fuer verwaist und loescht es. Deshalb wird schon das Soll gekuerzt.
    (:background)
    function shorten(name as String) as String {
        if (name.length() <= NAME_LIMIT) { return name; }
        return name.substring(0, NAME_LIMIT) as String;
    }

    //! Die Soll-Namen einer Liste so, wie sie vom Geraet zurueckkommen werden.
    //!
    //! Zwei Orte koennen auf denselben Rumpf fallen - "Restaurant Zum Alten
    //! Wirt" und "Restaurant Zum Neuen Wirt" enden beide bei "Restaurant Zum".
    //! Fuer den namensbasierten Abgleich waeren das derselbe Wegpunkt: der
    //! zweite bliebe ungeschrieben und beide verschwaenden gemeinsam. Der
    //! Doppelgaenger bekommt deshalb eine Kennziffer.
    (:background)
    function deviceNames(names as Array<String>) as Array<String> {
        var out = [] as Array<String>;
        for (var i = 0; i < names.size(); i++) {
            out.add(distinct(shorten(names[i]), out));
        }
        return out;
    }

    //! `name` selbst, oder die erste freie Variante mit angehaengter Kennziffer.
    (:background)
    function distinct(name as String, taken as Array<String>) as String {
        if (!Util.contains(taken, name)) { return name; }
        for (var n = 2; n < 100; n++) {
            var suffix = "~" + n.toString();
            var room = NAME_LIMIT - suffix.length();
            var stem = (name.length() > room) ? name.substring(0, room) as String : name;
            var candidate = stem + suffix;
            if (!Util.contains(taken, candidate)) { return candidate; }
        }
        // Mehr als achtundneunzig Orte mit demselben Rumpf: dann steht eben
        // einer doppelt da. Das ist immer noch besser als gar kein Ergebnis.
        return name;
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
