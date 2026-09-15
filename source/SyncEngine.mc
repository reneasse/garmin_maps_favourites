import Toybox.Lang;
using Toybox.Communications;
using Toybox.PersistedContent;
using Toybox.System;

//! Der Abgleich als Zustandsautomat: Katalog -> Seiten -> Differenz -> Anwenden.
//!
//! Dieselbe Klasse laeuft im Vordergrund und im Hintergrunddienst, die
//! Unterschiede stecken in zwei Feldern:
//!
//!   _havePresent  Im Vordergrund wird der Ist-Stand des Geraets einmal
//!                 eingelesen. Damit kommen von Hand geloeschte Favoriten
//!                 zurueck, verwaiste Eintraege verschwinden, und gemerkt wird
//!                 nur, was danach wirklich am Geraet steht.
//!                 Im Hintergrund waere dieser Durchlauf zu teuer: dort stehen
//!                 nur 32 kB Heap zur Verfuegung.
//!   _budget       Der Hintergrundlauf wendet hoechstens MAX_OPS_BACKGROUND
//!                 Aenderungen an. Was liegen bleibt, wird nicht gemerkt,
//!                 sondern der Hash der Liste bleibt leer - der naechste Lauf
//!                 holt sie erneut und arbeitet den Rest ab. Ein Abbruch
//!                 hinterlaesst so nie einen falschen, nur einen unfertigen
//!                 Zustand.
//!
//! Verglichen wird durchgehend ueber Geraetenamen, nicht ueber die Namen aus
//! der Google-Liste - siehe WaypointWriter.shorten(). Wer das aufweicht, bekommt
//! wieder den Fehler, an dem die App zuerst gescheitert ist: nichts wird
//! wiedergefunden, und die Aufraeumrunde loescht den eigenen Bestand.
(:background)
class SyncEngine {

    //! Eine Operation ist ein geschriebener oder geloeschter Wegpunkt.
    static const MAX_OPS_BACKGROUND = 20;
    static const MAX_OPS_FOREGROUND = 500;

    //! Ab so vielen Loeschungen auf einmal wird nachgefragt statt gehandelt.
    //! Unter diesem Sockel gilt jede Loeschung als normale Pflege.
    static const BULK_FLOOR = 5;

    hidden var _background as Boolean;
    hidden var _notify as Lang.Method or Null;

    hidden var _running as Boolean = false;
    hidden var _catalog as Array or Null = null;
    hidden var _queue as Array<String> = [] as Array<String>;
    hidden var _done as Number = 0;
    hidden var _total as Number = 0;

    hidden var _curId as String = "";
    hidden var _curHash as String = "";
    hidden var _curPages as Number = 0;
    hidden var _curPage as Number = 0;
    hidden var _places as Array = [] as Array;

    //! Die Geraetenamen zu _places, streng in derselben Reihenfolge -
    //! findPlace() findet ueber diesen Index von einem Namen zum Ort zurueck.
    hidden var _names as Array<String> = [] as Array<String>;

    hidden var _present as Array<String> = [] as Array<String>;
    hidden var _havePresent as Boolean = false;

    hidden var _ops as Number = 0;
    hidden var _budget as Number = 0;
    hidden var _partial as Boolean = false;
    hidden var _blocked as Number = 0;
    hidden var _bulkOk as Boolean = false;
    hidden var _error as Number = SyncStore.STAT_OK;

    function initialize(background as Boolean, notify as Lang.Method or Null) {
        _background = background;
        _notify = notify;
        _budget = background ? MAX_OPS_BACKGROUND : MAX_OPS_FOREGROUND;
    }

    function isRunning() as Boolean {
        return _running;
    }

    function progressDone() as Number {
        return _done;
    }

    function progressTotal() as Number {
        return _total;
    }

    //! Startet einen Abgleich. `bulkOk` hebt die Loeschsperre einmalig auf -
    //! das setzt der Vordergrund nach einer Rueckfrage beim Nutzer.
    //! Rueckgabe false heisst: es lief schon einer, oder eine Vorbedingung
    //! fehlte (der Grund steht dann im Status).
    function start(bulkOk as Boolean) as Boolean {
        if (_running) { return false; }

        _bulkOk = bulkOk;
        _running = true;
        _done = 0;
        _total = 0;
        _ops = 0;
        _partial = false;
        _blocked = 0;
        _error = SyncStore.STAT_OK;
        _catalog = null;
        _places = [] as Array;
        _names = [] as Array<String>;

        if (!WaypointWriter.available()) {
            finish(SyncStore.STAT_NO_API);
            return false;
        }
        if (!Settings.configured()) {
            finish(SyncStore.STAT_NO_URL);
            return false;
        }
        if (!connected()) {
            finish(SyncStore.STAT_NO_CONN);
            return false;
        }
        // Abgewaehlte Listen zuerst raeumen: das braucht kein Netz, und die
        // Wegpunkte sollen auch dann verschwinden, wenn der Abruf scheitert.
        // Eine leere Auswahl bricht hier bewusst nicht ab - der Katalog wird
        // trotzdem geholt, denn genau daraus baut sich die Listenauswahl am
        // Geraet auf.
        pruneDeselected();

        if (!_background) {
            _present = WaypointWriter.presentNames();
            _havePresent = true;
        }

        announce();
        fetchCatalog();
        return true;
    }

    // -- Abruf -----------------------------------------------------------------

    hidden function fetchCatalog() as Void {
        request(Settings.serviceUrl + "index.json", method(:onCatalogResponse));
    }

    hidden function fetchPage() as Void {
        var url = Settings.serviceUrl + "l/" + _curId + "/" + _curPage.toString() + ".json";
        request(url, method(:onPageResponse));
    }

    hidden function request(url as String, callback as Lang.Method) as Void {
        Communications.makeWebRequest(url, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "Accept" => "application/json" },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, callback);
    }

    //! Die Signatur ist ausgeschrieben, weil makeWebRequest den Callback gegen
    //! die eigene Union typprueft und ein blankes (code, data) ablehnt.
    function onCatalogResponse(
        code as Lang.Number,
        data as Lang.Dictionary or Lang.String or PersistedContent.Iterator or Null
    ) as Void {
        if (code != 200) {
            finish(code);
            return;
        }
        var catalog = Feed.parseCatalog(data);
        if (catalog == null) {
            finish(SyncStore.STAT_BAD_DATA);
            return;
        }
        _catalog = catalog;
        SyncStore.saveCatalog(catalog);

        var selection = SyncStore.selection();
        if (selection.size() == 0) {
            finish(SyncStore.STAT_NO_LISTS);
            return;
        }
        var planned = buildQueue(catalog, selection);
        if (planned == null) {
            finish(SyncStore.STAT_TOO_MANY);
            return;
        }
        _queue = planned;
        _total = _queue.size();
        announce();
        beginNextList();
    }

    function onPageResponse(
        code as Lang.Number,
        data as Lang.Dictionary or Lang.String or PersistedContent.Iterator or Null
    ) as Void {
        if (code != 200) {
            // Eine kaputte Liste stoppt nicht den ganzen Lauf - der Fehler wird
            // gemerkt und die naechste Liste angegangen.
            _error = code;
            beginNextList();
            return;
        }
        var page = Feed.parsePage(data, _curId, _curHash);
        if (page == null) {
            _error = SyncStore.STAT_BAD_DATA;
            beginNextList();
            return;
        }
        _places.addAll(page);
        _curPage++;
        if (_curPage < _curPages) {
            fetchPage();
            return;
        }
        applyCurrentList();
    }

    // -- Planung ---------------------------------------------------------------

    //! Welche Listen muessen wirklich geholt werden? Null bedeutet: die Auswahl
    //! sprengt die Favoriten-Obergrenze, es wird nichts angefasst.
    //!
    //! Getrennt vom Netzcode, damit die Entscheidung testbar bleibt.
    function buildQueue(catalog as Array, selection as Array<String>) as Array<String> or Null {
        var total = 0;
        var queue = [] as Array<String>;

        for (var i = 0; i < selection.size(); i++) {
            var id = selection[i];
            var entry = Feed.findList(catalog, id);
            if (entry == null) { continue; }

            var count = entry[Feed.C_COUNT];
            if (count instanceof Number) { total += count; }

            var hash = entry[Feed.C_HASH];
            if (!(hash instanceof String)) { continue; }
            if (needsFetch(id, hash)) { queue.add(id); }
        }

        if (total > Settings.maxFavourites) {
            _blocked = total;
            return null;
        }
        return queue;
    }

    //! Geholt wird, wenn sich der Inhalt geaendert hat - oder wenn im
    //! Vordergrund auffaellt, dass ein gespeicherter Favorit am Geraet fehlt.
    hidden function needsFetch(id as String, hash as String) as Boolean {
        var stored = SyncStore.listHash(id);
        if (!stored.equals(hash)) { return true; }
        if (!_havePresent) { return false; }
        var names = SyncStore.listNames(id);
        for (var i = 0; i < names.size(); i++) {
            if (!Util.contains(_present, names[i])) { return true; }
        }
        return false;
    }

    //! Wegpunkte von Listen entfernen, die der Nutzer abgewaehlt hat.
    //! Das ist eine ausdrueckliche Nutzeraktion und umgeht die Loeschsperre.
    hidden function pruneDeselected() as Void {
        var selection = SyncStore.selection();
        var known = SyncStore.knownIds();
        for (var i = 0; i < known.size(); i++) {
            var id = known[i];
            if (Util.contains(selection, id)) { continue; }
            var names = SyncStore.listNames(id);
            SyncStore.dropList(id);
            WaypointWriter.removeNames(names, SyncStore.allKnownNames());
        }
    }

    // -- Anwenden --------------------------------------------------------------

    hidden function beginNextList() as Void {
        _places = [] as Array;
        _names = [] as Array<String>;

        if (_queue.size() == 0) {
            finalise();
            return;
        }
        _curId = _queue[0];
        _queue = _queue.slice(1, null) as Array<String>;

        var entry = Feed.findList(_catalog, _curId);
        if (entry == null) {
            _done++;
            beginNextList();
            return;
        }
        _curHash = entry[Feed.C_HASH] as String;
        _curPages = entry[Feed.C_PAGES] as Number;
        _curPage = 0;

        if (_curPages == 0) {
            // Serverseitig leere Liste: nur zulaessig, wenn hier auch nichts
            // steht. Sonst greift dieselbe Sperre wie bei einer leeren Antwort.
            applyCurrentList();
            return;
        }
        announce();
        fetchPage();
    }

    hidden function applyCurrentList() as Void {
        // Das Soll steht von hier an in Geraetenamen. Der Ortsspeicher kuerzt,
        // und verglichen, gemerkt und geloescht wird ausschliesslich ueber den
        // Namen - also muss das Soll schon so aussehen, wie es zurueckkommt.
        _names = WaypointWriter.deviceNames(Feed.names(_places));
        var desired = _names;
        var old = SyncStore.listNames(_curId);

        // Sperre 1: eine leer gewordene Liste ist fast immer ein kaputter
        // Scraper, kein geleerter Ordner. Im Zweifel bleibt alles stehen.
        if (desired.size() == 0 && old.size() > 0) {
            _error = SyncStore.STAT_EMPTY;
            _done++;
            beginNextList();
            return;
        }

        var reference = _havePresent ? _present : old;
        var toAdd = Util.difference(desired, reference);
        var toDel = Util.difference(old, desired);

        // Sperre 2: ungewoehnlich viele Loeschungen auf einmal.
        if (blocksBulkDelete(toDel.size(), old.size())) {
            _blocked = toDel.size();
            _error = SyncStore.STAT_BULK;
            _done++;
            beginNextList();
            return;
        }

        if (toDel.size() > 0) {
            WaypointWriter.removeNames(toDel, SyncStore.namesExcept(_curId));
            _ops += toDel.size();
        }

        var added = addPlaces(toAdd);
        if (!storeResult(desired, added >= toAdd.size())) { _partial = true; }
        _done++;
        beginNextList();
    }

    //! Loeschsperre: mehr als die Haelfte des Bestandes und mehr als BULK_FLOOR.
    function blocksBulkDelete(deletions as Number, stored as Number) as Boolean {
        if (_bulkOk || Settings.allowBulkDelete) { return false; }
        if (deletions <= BULK_FLOOR) { return false; }
        return deletions > stored / 2;
    }

    //! Schreibt so viele Orte, wie das Budget hergibt; liefert die Anzahl.
    hidden function addPlaces(toAdd as Array<String>) as Number {
        var added = 0;
        for (var i = 0; i < toAdd.size(); i++) {
            if (_ops >= _budget) { break; }
            var place = findPlace(toAdd[i]);
            if (place == null) { continue; }
            // Geschrieben wird der schon gekuerzte Name, nicht der aus der
            // Liste: nur so ist der zurueckgelesene mit dem gewuenschten gleich.
            var ok = WaypointWriter.add(
                toAdd[i],
                place[Feed.E_LAT] as Float,
                place[Feed.E_LON] as Float
            );
            _ops++;
            if (ok) { added++; }
        }
        return added;
    }

    //! `name` ist ein Geraetename, also der gekuerzte. Gesucht wird ueber
    //! _names, weil der Ort selbst noch den vollen Namen traegt.
    hidden function findPlace(name as String) as Array or Null {
        var n = _names.size();
        if (n > _places.size()) { n = _places.size(); }
        for (var i = 0; i < n; i++) {
            if (!_names[i].equals(name)) { continue; }
            var p = _places[i];
            if (p instanceof Array && p.size() > Feed.E_LON) { return p; }
        }
        return null;
    }

    //! Im Vordergrund wird der Ist-Stand zurueckgelesen und nur das gemerkt,
    //! was dort auch wirklich steht. Im Hintergrund fehlt dafuer der Speicher;
    //! dort korrigiert der naechste Vordergrundlauf.
    //!
    //! Rueckgabe: ob die Liste vollstaendig auf dem Geraet steht.
    //!
    //! Massgeblich ist das Zurueckgelesene, nicht der Rueckgabewert von
    //! saveWaypoint(). Ist die Standortliste voll, meldet saveWaypoint weiter
    //! Erfolg, und der Wegpunkt fehlt trotzdem - ohne diese Pruefung wuerde die
    //! App den Hash speichern und sich fuer fertig halten.
    hidden function storeResult(desired as Array<String>, withinBudget as Boolean) as Boolean {
        var written = desired;
        var complete = withinBudget;

        if (_havePresent) {
            _present = WaypointWriter.presentNames();
            written = Util.intersection(desired, _present);
            complete = isComplete(desired, _present, withinBudget);
        }

        // Leerer Hash = unfertig: der naechste Lauf holt die Liste erneut.
        SyncStore.saveList(_curId, complete ? _curHash : "", written);
        return complete;
    }

    //! Steht wirklich alles Gewuenschte am Geraet?
    //!
    //! Getrennt herausgezogen, weil daran die Ehrlichkeit der Anzeige haengt:
    //! ist die Standortliste voll, meldet saveWaypoint() weiter Erfolg. Nur der
    //! zurueckgelesene Bestand darf entscheiden.
    function isComplete(
        desired as Array<String>, present as Array<String>, withinBudget as Boolean
    ) as Boolean {
        if (!withinBudget) { return false; }
        for (var i = 0; i < desired.size(); i++) {
            if (!Util.contains(present, desired[i])) { return false; }
        }
        return true;
    }

    // -- Abschluss -------------------------------------------------------------

    //! Aufraeumen am Ende: alles, was diese App angelegt hat und keine Liste
    //! mehr beansprucht, fliegt raus. Braucht den Ist-Stand, laeuft deshalb nur
    //! im Vordergrund.
    //!
    //! Und nur nach einem sauberen Lauf. Blieb eine Liste unfertig, ist der
    //! gemerkte Bestand kleiner als der tatsaechliche - die Differenz waere
    //! dann kein Waisenkind, sondern genau das, was gerade geschrieben wurde.
    //! Genau so hat sich die App ihre eigenen Favoriten wieder abgeraeumt.
    //! Liegenbleiben kostet nichts: der naechste vollstaendige Lauf raeumt auf.
    hidden function finalise() as Void {
        if (_havePresent && _error == SyncStore.STAT_OK && !_partial) {
            var keep = SyncStore.allKnownNames();
            var orphans = Util.difference(WaypointWriter.presentNames(), keep);
            if (orphans.size() > 0) {
                WaypointWriter.removeNames(orphans, [] as Array<String>);
            }
        }
        var code = _error;
        if (code == SyncStore.STAT_OK && _partial) { code = SyncStore.STAT_PARTIAL; }
        finish(code);
    }

    hidden function finish(code as Number) as Void {
        _running = false;
        _catalog = null;
        _places = [] as Array;
        _names = [] as Array<String>;
        _present = [] as Array<String>;
        SyncStore.saveStatus(code, SyncStore.syncedCount(), _blocked);
        Log.d("sync fertig, code " + code.toString());
        announce();
    }

    hidden function announce() as Void {
        var n = _notify;
        if (n != null) { n.invoke(); }
    }

    hidden function connected() as Boolean {
        var settings = System.getDeviceSettings();
        if (settings has :connectionAvailable) {
            var available = settings.connectionAvailable;
            if (available instanceof Boolean) { return available; }
        }
        return true;
    }
}
