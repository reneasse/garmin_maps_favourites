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

    //! Was das Geraet von einem geschriebenen Namen zurueckgibt, entscheidet
    //! ueber den ganzen Abgleich - verglichen, gemerkt und geloescht wird nur
    //! ueber den Namen. Zwei Regeln sind dabei nachgemessen, beide teuer:
    //!
    //!   Laenge. Der Ortsspeicher schneidet wortlos ab, und wo die Grenze
    //!   liegt, sagen Simulator und Geraet verschieden: der Simulator (Edge
    //!   540, 840, 1040, 1050) bei fuenfzehn *Zeichen*, das Geraet bei
    //!   fuenfzehn *Bytes*. Gekuerzt wird deshalb auf Bytes - die engere der
    //!   beiden Regeln, und sie erfuellt beide.
    //!
    //!   Zeichenvorrat. Nur ASCII kommt unveraendert zurueck. "Restaurant
    //!   Hane" - fuenfzehn ASCII-Bytes, also genau an der Grenze - laeuft
    //!   durch; "REWE Frederic" mit zwei Akzent-e, ebenfalls auf fuenfzehn
    //!   Bytes gekuerzt, kam nicht unveraendert zurueck - an der Laenge liegt
    //!   es also nicht. Der Wegpunkt stand danach sichtbar auf dem Geraet, war
    //!   ueber seinen Namen aber nicht mehr zu finden: die Liste blieb
    //!   dauerhaft auf "teilweise uebertragen", jeder Lauf schrieb ihn erneut,
    //!   und die Aufraeumrunde kam nie zum Zug.
    //!
    //! Deshalb wird zuerst nach ASCII gefaltet und erst dann gekuerzt - in
    //! dieser Reihenfolge, damit die Ersatzschreibweise (ae, oe, ue, ss) noch
    //! ins Budget zaehlt. Umlaute kosten danach nichts mehr, und die Grenze
    //! ist wieder dieselbe Zahl fuer Zeichen wie fuer Bytes.
    //!
    //! Der Simulator zeigt beide Fehler nicht und kann sie nicht zeigen: er
    //! ist grosszuegiger als das Geraet. Was hier steht, ist auf Hardware
    //! gemessen.

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

    //! Was ein Zeichen im Ortsspeicher kostet: seine Laenge in UTF-8.
    (:background)
    function charCost(code as Number) as Number {
        if (code < 0x80) { return 1; }
        if (code < 0x800) { return 2; }
        if (code < 0x10000) { return 3; }
        return 4;
    }

    //! Die Laenge eines Namens so, wie der Ortsspeicher sie zaehlt.
    (:background)
    function byteLength(name as String) as Number {
        var chars = name.toCharArray();
        var bytes = 0;
        for (var i = 0; i < chars.size(); i++) {
            bytes += charCost(chars[i].toNumber());
        }
        return bytes;
    }

    //! Der laengste Anfang von `name`, der in `budget` Bytes passt.
    //!
    //! Zusammengesetzt aus dem Zeichen-Array statt ueber substring(): Zeichen-
    //! und Byte-Index laufen bei Akzenten auseinander, und ein Schnitt mitten
    //! in einem Zeichen ergaebe einen Namen, den das Geraet nie zurueckgibt.
    (:background)
    function cut(name as String, budget as Number) as String {
        var chars = name.toCharArray();
        var bytes = 0;
        var out = "";
        for (var i = 0; i < chars.size(); i++) {
            var cost = charCost(chars[i].toNumber());
            if (bytes + cost > budget) { break; }
            bytes += cost;
            out += chars[i].toString();
        }
        return out;
    }

    //! Ersatzbuchstaben fuer Latin-1 (0xC0-0xFF) und Latin Extended-A
    //! (0x100-0x17F), ein Zeichen je Position. Was eine eingebuergerte
    //! Ersatzschreibweise aus zwei Buchstaben hat - die Umlaute, ss, Th -
    //! steht als Sonderfall in foldChar() davor.
    const FOLD_LATIN1 = "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty";
    const FOLD_LATIN_A = "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiIiJjKkkLlLlLlLlLlNnNnNnnNnOoOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs";

    //! Ein Zeichen als ASCII. Leer heisst: dafuer gibt es keins.
    (:background)
    function foldChar(code as Number) as String {
        if (code >= 0x20 && code < 0x7F) { return code.toChar().toString(); }
        if (code == 0xA0) { return " "; }
        // Was im Deutschen ausgeschrieben wird, statt nur den Punkt zu verlieren.
        if (code == 0xC4) { return "Ae"; }
        if (code == 0xD6) { return "Oe"; }
        if (code == 0xDC) { return "Ue"; }
        if (code == 0xE4) { return "ae"; }
        if (code == 0xF6) { return "oe"; }
        if (code == 0xFC) { return "ue"; }
        if (code == 0xDF) { return "ss"; }
        if (code == 0xC6) { return "Ae"; }
        if (code == 0xE6) { return "ae"; }
        if (code == 0x152) { return "Oe"; }
        if (code == 0x153) { return "oe"; }
        if (code == 0xDE) { return "Th"; }
        if (code == 0xFE) { return "th"; }
        // Typografie, die in Ortsnamen wirklich vorkommt: Gedankenstriche und
        // das krumme Apostroph.
        if (code >= 0x2010 && code <= 0x2015) { return "-"; }
        if (code == 0x2018 || code == 0x2019 || code == 0x201B) { return "'"; }
        if (code >= 0xC0 && code <= 0xFF) { return at(FOLD_LATIN1, code - 0xC0); }
        if (code >= 0x100 && code <= 0x17F) { return at(FOLD_LATIN_A, code - 0x100); }
        return "";
    }

    (:background)
    function at(table as String, index as Number) as String {
        return table.substring(index, index + 1) as String;
    }

    //! Der ganze Name als ASCII, ohne doppelte oder aeussere Leerzeichen.
    //!
    //! Die Leerzeichen sind kein Schoenheitsdienst: faellt ein Zeichen weg,
    //! fuer das es kein ASCII gibt, bliebe sonst eine Luecke stehen - und ein
    //! Name mit Leerzeichen am Ende ist genau die Sorte, bei der niemand
    //! zusichern kann, dass das Geraet ihn unangetastet zurueckgibt.
    (:background)
    function fold(name as String) as String {
        var chars = name.toCharArray();
        var out = "";
        var pending = false;
        for (var i = 0; i < chars.size(); i++) {
            var piece = foldChar(chars[i].toNumber());
            if (piece.length() == 0) { continue; }
            if (piece.equals(" ")) {
                pending = out.length() > 0;
                continue;
            }
            if (pending) {
                out += " ";
                pending = false;
            }
            out += piece;
        }
        return out;
    }

    //! Leerzeichen am Ende abschneiden - siehe fold().
    (:background)
    function trimEnd(name as String) as String {
        var s = name;
        while (s.length() > 0 && s.substring(s.length() - 1, s.length()).equals(" ")) {
            s = s.substring(0, s.length() - 1) as String;
        }
        return s;
    }

    //! Der Name, unter dem das Geraet einen Ort fuehren wird: gefaltet, dann
    //! gekuerzt.
    //!
    //! Der Abgleich vergleicht Soll und Ist ausschliesslich ueber den Namen.
    //! Gibt das Geraet etwas anderes zurueck, als hineingegangen ist - weil er
    //! zu lang war oder weil er Akzente trug -, findet sich kein einziger
    //! Wegpunkt wieder: die App meldet "teilweise uebertragen", merkt sich
    //! nichts, und die Aufraeumrunde haelt alles gerade Geschriebene fuer
    //! verwaist und loescht es. Deshalb steht schon das Soll in der Form, die
    //! zurueckkommen wird.
    (:background)
    function shorten(name as String) as String {
        var folded = fold(name);
        // Bleibt nichts Lesbares uebrig - ein Name ganz ohne lateinische
        // Zeichen -, ist der rohe Name immer noch besser als gar keiner. Er
        // wird sich am Geraet vermutlich nicht wiederfinden lassen, aber das
        // trifft dann genau diesen einen Ort.
        if (folded.length() == 0) { folded = name; }
        if (byteLength(folded) <= NAME_LIMIT) { return folded; }
        return trimEnd(cut(folded, NAME_LIMIT));
    }

    //! Die Soll-Namen einer Liste so, wie sie vom Geraet zurueckkommen werden.
    //!
    //! Zwei Orte koennen auf denselben Rumpf fallen - "Restaurant Zum Alten
    //! Wirt" und "Restaurant Zum Neuen Wirt" enden beide bei "Restaurant Zum".
    //! Das Falten schafft dieselbe Lage noch einmal: "Cafe" und ein "Cafe" mit
    //! Akzent sind danach derselbe Name. Fuer den namensbasierten Abgleich
    //! waere das jeweils derselbe Wegpunkt: der zweite bliebe ungeschrieben
    //! und beide verschwaenden gemeinsam. Der Doppelgaenger bekommt deshalb
    //! eine Kennziffer.
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
            // Die Kennziffer braucht Platz im selben Byte-Budget: sonst faellt
            // sie beim Schreiben wieder ab und die Doppelgaenger sind zurueck.
            var suffix = "~" + n.toString();
            var candidate = trimEnd(cut(name, NAME_LIMIT - byteLength(suffix))) + suffix;
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
