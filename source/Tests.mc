import Toybox.Lang;
using Toybox.Test;

//! Alles, was ohne Geraet und ohne Netz entscheidbar ist.
//!
//! Der Schwerpunkt liegt auf den beiden Stellen, an denen ein Fehler Favoriten
//! kostet: der Auswertung fremder Antworten und der Differenzbildung samt ihren
//! Sperren. Der Rest der App faellt bei einem Fehler hoechstens unangenehm auf.

// -- Settings ----------------------------------------------------------------

(:test)
function urlGetsTrailingSlash(logger as Test.Logger) as Boolean {
    Test.assertEqual(Settings.normaliseUrl("https://a.b/c"), "https://a.b/c/");
    Test.assertEqual(Settings.normaliseUrl("https://a.b/c/"), "https://a.b/c/");
    return true;
}

(:test)
function urlEmptyStaysEmpty(logger as Test.Logger) as Boolean {
    Test.assertEqual(Settings.normaliseUrl(""), "");
    Test.assertEqual(Settings.normaliseUrl("   "), "");
    return true;
}

// -- Util --------------------------------------------------------------------

(:test)
function containsComparesByValue(logger as Test.Logger) as Boolean {
    // Entscheidend: der Vergleich darf nicht an Objektidentitaet haengen,
    // sonst faende der Abgleich nie einen bereits geschriebenen Namen wieder.
    var built = "Cafe" + " Central";
    Test.assert(Util.contains(["Cafe Central", "Bar"] as Array<String>, built));
    Test.assert(!Util.contains(["Bar"] as Array<String>, built));
    return true;
}

(:test)
function differenceKeepsOnlyMissing(logger as Test.Logger) as Boolean {
    var a = ["a", "b", "c"] as Array<String>;
    var b = ["b"] as Array<String>;
    var d = Util.difference(a, b);
    Test.assertEqual(d.size(), 2);
    Test.assert(Util.contains(d, "a"));
    Test.assert(Util.contains(d, "c"));
    Test.assertEqual(Util.difference(b, a).size(), 0);
    return true;
}

(:test)
function coordsAreSanityChecked(logger as Test.Logger) as Boolean {
    Test.assert(Util.validCoord(48.137, 11.575));
    Test.assert(!Util.validCoord(0.0, 0.0));
    Test.assert(!Util.validCoord(91.0, 11.0));
    Test.assert(!Util.validCoord(48.0, 181.0));
    return true;
}

(:test)
function ageIsFormattedByMagnitude(logger as Test.Logger) as Boolean {
    Test.assertEqual(Util.formatAge(30), "30 s");
    Test.assertEqual(Util.formatAge(120), "2 min");
    Test.assertEqual(Util.formatAge(7200), "2 h");
    Test.assertEqual(Util.formatAge(3 * 86400), "3 d");
    return true;
}

// -- Feed: Katalog -----------------------------------------------------------

(:test)
function catalogIsParsed(logger as Test.Logger) as Boolean {
    var raw = {
        "v" => 1,
        "t" => 1757260800,
        "l" => [
            { "i" => "aa", "n" => "Cafes", "c" => 37, "h" => "h1", "p" => 2 },
            { "i" => "bb", "n" => "Aussicht", "c" => 4, "h" => "h2", "p" => 1 }
        ]
    };
    var cat = Feed.parseCatalog(raw);
    Test.assert(cat != null);
    Test.assertEqual(cat.size(), 2);
    var first = cat[0] as Array;
    Test.assertEqual(first[Feed.C_ID] as String, "aa");
    Test.assertEqual(first[Feed.C_COUNT] as Number, 37);
    Test.assertEqual(first[Feed.C_PAGES] as Number, 2);
    return true;
}

(:test)
function catalogRejectsForeignSchema(logger as Test.Logger) as Boolean {
    // Ein Versionssprung darf nicht als leerer Katalog durchgehen - daraus
    // wuerden Loeschungen auf dem Geraet.
    Test.assert(Feed.parseCatalog({ "v" => 2, "l" => [] }) == null);
    Test.assert(Feed.parseCatalog({ "l" => [] }) == null);
    Test.assert(Feed.parseCatalog("nope") == null);
    Test.assert(Feed.parseCatalog(null) == null);
    return true;
}

(:test)
function catalogDropsBrokenEntries(logger as Test.Logger) as Boolean {
    var raw = {
        "v" => 1,
        "l" => [
            { "i" => "aa", "n" => "Ok", "c" => 1, "h" => "h1", "p" => 1 },
            { "i" => "bb", "n" => "Kein Hash", "c" => 1, "p" => 1 },
            { "n" => "Keine Id", "c" => 1, "h" => "h3", "p" => 1 },
            "unfug"
        ]
    };
    var cat = Feed.parseCatalog(raw);
    Test.assertEqual(cat.size(), 1);
    return true;
}

(:test)
function findListMatchesById(logger as Test.Logger) as Boolean {
    var cat = Feed.parseCatalog({
        "v" => 1,
        "l" => [{ "i" => "aa", "n" => "Ok", "c" => 1, "h" => "h1", "p" => 1 }]
    });
    Test.assert(Feed.findList(cat, "aa") != null);
    Test.assert(Feed.findList(cat, "zz") == null);
    Test.assert(Feed.findList(null, "aa") == null);
    return true;
}

// -- Feed: Seiten ------------------------------------------------------------

(:test)
function pageIsParsed(logger as Test.Logger) as Boolean {
    var raw = {
        "i" => "aa", "h" => "h1", "p" => 0, "n" => 1,
        "e" => [["Cafe Central", 48.13721, 11.57559]]
    };
    var page = Feed.parsePage(raw, "aa", "h1");
    Test.assert(page != null);
    Test.assertEqual(page.size(), 1);
    var names = Feed.names(page);
    Test.assertEqual(names[0], "Cafe Central");
    return true;
}

(:test)
function pageRejectsMismatchedHash(logger as Test.Logger) as Boolean {
    // Laeuft der Backend-Build mitten im Abgleich durch, kaeme Seite 0 vom
    // alten und Seite 1 vom neuen Stand. Der Hash faengt genau das ab.
    var raw = { "i" => "aa", "h" => "h2", "e" => [["X", 48.0, 11.0]] };
    Test.assert(Feed.parsePage(raw, "aa", "h1") == null);
    Test.assert(Feed.parsePage(raw, "bb", "h2") == null);
    return true;
}

(:test)
function pageDropsBrokenPlaces(logger as Test.Logger) as Boolean {
    var raw = {
        "i" => "aa", "h" => "h1",
        "e" => [
            ["Gut", 48.0, 11.0],
            ["Nullinsel", 0.0, 0.0],
            ["Unvollstaendig", 48.0],
            [48.0, 11.0, "Namenlos"],
            "unfug"
        ]
    };
    var page = Feed.parsePage(raw, "aa", "h1");
    Test.assertEqual(page.size(), 1);
    Test.assertEqual(Feed.names(page)[0], "Gut");
    return true;
}

(:test)
function pageAcceptsIntegerCoords(logger as Test.Logger) as Boolean {
    // Ein glatter Wert kommt als Number aus dem JSON-Parser, nicht als Float.
    var page = Feed.parsePage({ "i" => "aa", "h" => "h1", "e" => [["X", 48, 11]] }, "aa", "h1");
    Test.assertEqual(page.size(), 1);
    return true;
}

// -- Sperren -----------------------------------------------------------------

(:test)
function bulkDeleteGuardHasFloorAndRatio(logger as Test.Logger) as Boolean {
    Settings.load();
    var engine = new SyncEngine(true, null);

    // Kleine Pflege bleibt erlaubt, auch wenn sie den ganzen Bestand trifft.
    Test.assert(!engine.blocksBulkDelete(3, 4));
    Test.assert(!engine.blocksBulkDelete(5, 5));
    // Darueber zaehlt das Verhaeltnis.
    Test.assert(engine.blocksBulkDelete(20, 30));
    Test.assert(!engine.blocksBulkDelete(20, 60));
    return true;
}

(:test)
function bulkOverrideLiftsGuard(logger as Test.Logger) as Boolean {
    Settings.load();
    var engine = new SyncEngine(true, null);
    Test.assert(engine.blocksBulkDelete(20, 30));

    // start() setzt das Zugestaendnis des Nutzers; ohne Dienst-URL bricht es
    // gleich wieder ab, das Flag bleibt aber gesetzt.
    Settings.serviceUrl = "";
    engine.start(true);
    Test.assert(!engine.blocksBulkDelete(20, 30));
    return true;
}

// -- Warteschlange -----------------------------------------------------------

(:test)
function queueSkipsUnchangedLists(logger as Test.Logger) as Boolean {
    Settings.load();
    Settings.maxFavourites = 200;
    SyncStore.forgetAll();
    SyncStore.saveList("aa", "h1", ["X"] as Array<String>);

    var cat = Feed.parseCatalog({
        "v" => 1,
        "l" => [
            { "i" => "aa", "n" => "Unveraendert", "c" => 1, "h" => "h1", "p" => 1 },
            { "i" => "bb", "n" => "Neu", "c" => 1, "h" => "h9", "p" => 1 }
        ]
    });

    var engine = new SyncEngine(true, null);
    var queue = engine.buildQueue(cat, ["aa", "bb"] as Array<String>);
    Test.assert(queue != null);
    Test.assertEqual(queue.size(), 1);
    Test.assertEqual(queue[0], "bb");

    SyncStore.forgetAll();
    return true;
}

(:test)
function queueRefetchesAfterIncompleteRun(logger as Test.Logger) as Boolean {
    // Leerer Hash heisst "unfertig": die Liste muss erneut geholt werden.
    Settings.load();
    Settings.maxFavourites = 200;
    SyncStore.forgetAll();
    SyncStore.saveList("aa", "", ["X"] as Array<String>);

    var cat = Feed.parseCatalog({
        "v" => 1,
        "l" => [{ "i" => "aa", "n" => "Unfertig", "c" => 1, "h" => "h1", "p" => 1 }]
    });
    var engine = new SyncEngine(true, null);
    var queue = engine.buildQueue(cat, ["aa"] as Array<String>);
    Test.assertEqual(queue.size(), 1);

    SyncStore.forgetAll();
    return true;
}

(:test)
function queueRefusesOverLimit(logger as Test.Logger) as Boolean {
    Settings.load();
    Settings.maxFavourites = 10;
    SyncStore.forgetAll();

    var cat = Feed.parseCatalog({
        "v" => 1,
        "l" => [
            { "i" => "aa", "n" => "Gross", "c" => 8, "h" => "h1", "p" => 1 },
            { "i" => "bb", "n" => "Auch gross", "c" => 8, "h" => "h2", "p" => 1 }
        ]
    });
    var engine = new SyncEngine(true, null);
    // Null heisst: nichts anfassen, sonst passt die Auswahl nicht aufs Geraet.
    Test.assert(engine.buildQueue(cat, ["aa", "bb"] as Array<String>) == null);
    Test.assert(engine.buildQueue(cat, ["aa"] as Array<String>) != null);
    return true;
}

// -- Vollstaendigkeit --------------------------------------------------------

(:test)
function completenessFollowsTheDeviceNotTheReturnValue(logger as Test.Logger) as Boolean {
    // Die Regel, die im Simulator einen echten Fehler aufgedeckt hat: ist die
    // Standortliste voll, meldet saveWaypoint() weiter Erfolg und der Wegpunkt
    // fehlt trotzdem. Nur das Zurueckgelesene zaehlt - sonst speichert die App
    // den Hash und haelt sich fuer fertig.
    var engine = new SyncEngine(false, null);
    var desired = ["A", "B", "C"] as Array<String>;

    Test.assert(engine.isComplete(desired, ["A", "B", "C"] as Array<String>, true));
    Test.assert(!engine.isComplete(desired, ["A", "B"] as Array<String>, true));
    // Budget aufgebraucht schlaegt auch dann durch, wenn zufaellig alles steht.
    Test.assert(!engine.isComplete(desired, ["A", "B", "C"] as Array<String>, false));
    return true;
}

(:test)
function intersectionKeepsOnlyWhatIsPresent(logger as Test.Logger) as Boolean {
    var got = Util.intersection(
        ["A", "B", "C"] as Array<String>,
        ["B", "C", "D"] as Array<String>);
    Test.assertEqual(got.size(), 2);
    Test.assert(Util.contains(got, "B"));
    Test.assert(!Util.contains(got, "A"));
    return true;
}

// -- Namen -------------------------------------------------------------------

(:test)
function namesAreCutToWhatTheDeviceKeeps(logger as Test.Logger) as Boolean {
    // Der Fehler, an dem die App zuerst gescheitert ist: geschrieben wurde der
    // volle Name, zurueck kam der gekuerzte, und damit fand sich kein einziger
    // Wegpunkt wieder.
    Test.assertEqual(WaypointWriter.shorten("Restaurant Hanedan"), "Restaurant Hane");
    Test.assertEqual(WaypointWriter.shorten("Kurz"), "Kurz");
    // Genau auf der Grenze wird nicht angefasst.
    Test.assertEqual(WaypointWriter.shorten("ABCDEFGHIJKLMNO").length(), 15);
    Test.assertEqual(WaypointWriter.shorten("ABCDEFGHIJKLMNOP").length(), 15);
    return true;
}

//! Ein Akzent-e, ohne es in den Quelltext zu schreiben: der Compiler liest
//! diese Dateien als ASCII, und ein Literal haette hier still zwei Zeichen
//! ergeben - der Test wuerde dann etwas anderes pruefen, als er behauptet.
function eAcute() as String {
    return (233).toChar().toString();
}

(:test)
function namesAreCutByBytesNotCharacters(logger as Test.Logger) as Boolean {
    // Der Fehler, an dem ein echter Eintrag gescheitert ist: gekuerzt wurde
    // mit String.length(), und das zaehlt Zeichen. "REWE Frederic C" mit zwei
    // Akzent-e sind fuenfzehn Zeichen, aber siebzehn Bytes - auf dem Geraet
    // kam der Name nicht unveraendert zurueck, der Wegpunkt fand sich nie
    // wieder, und die Liste stand dauerhaft auf "teilweise uebertragen".
    var e = eAcute();
    var voll = "REWE Fr" + e + "d" + e + "ric Cahon";
    Test.assertEqual(voll.length(), 19);
    Test.assertEqual(WaypointWriter.byteLength(voll), 21);

    var kurz = WaypointWriter.shorten(voll);
    Test.assertEqual(kurz, "REWE Fr" + e + "d" + e + "ric");
    Test.assertEqual(WaypointWriter.byteLength(kurz), 15);
    // Was passt, bleibt unberuehrt - auch wenn es Akzente traegt.
    Test.assertEqual(WaypointWriter.shorten(kurz), kurz);

    // Nie mitten in einem Zeichen: ein halbes Akzent-e kaeme nie zurueck.
    var cafe = "Caf" + e;
    Test.assertEqual(WaypointWriter.cut(cafe, 4), "Caf");
    Test.assertEqual(WaypointWriter.cut(cafe, 5), cafe);

    // Reines ASCII rechnet unveraendert.
    Test.assertEqual(WaypointWriter.byteLength("Restaurant Hane"), 15);
    return true;
}

(:test)
function distinctSuffixSurvivesTheByteLimit(logger as Test.Logger) as Boolean {
    // Auch die Kennziffer muss ins Byte-Budget passen, sonst schneidet das
    // Geraet genau sie wieder ab - und die Doppelgaenger fallen zusammen.
    var e = eAcute();
    var got = WaypointWriter.deviceNames([
        "Caf" + e + " " + e + "toile Nord",
        "Caf" + e + " " + e + "toile Nordwest"
    ] as Array<String>);

    // Beide fallen auf denselben Rumpf: "Caf<e> <E>toile N" sind fuenfzehn
    // Bytes, und danach unterscheiden sie sich erst.
    Test.assertEqual(WaypointWriter.byteLength(got[0]), 15);
    Test.assert(!got[1].equals(got[0]));
    Test.assertEqual(got[1], "Caf" + e + " " + e + "toile~2");
    Test.assertEqual(WaypointWriter.byteLength(got[1]), 15);
    return true;
}

(:test)
function namesStayApartAfterCutting(logger as Test.Logger) as Boolean {
    // Zwei Orte mit gleichem Rumpf duerfen nicht zu einem Wegpunkt verschmelzen:
    // der zweite bliebe ungeschrieben, und beide gingen zusammen verloren.
    var got = WaypointWriter.deviceNames([
        "Restaurant Zum Alten Wirt",
        "Restaurant Zum Neuen Wirt",
        "Baecker"
    ] as Array<String>);

    Test.assertEqual(got.size(), 3);
    // Der Schnitt faellt mitten in den Namen, das Leerzeichen am Ende bleibt
    // stehen - das Geraet gibt es genauso zurueck, also darf es nicht weg.
    Test.assertEqual(got[0], "Restaurant Zum ");
    Test.assert(!got[1].equals(got[0]));
    Test.assert(WaypointWriter.byteLength(got[1]) <= WaypointWriter.NAME_LIMIT);
    Test.assertEqual(got[2], "Baecker");
    return true;
}

(:test)
function namesKeepTheirOrder(logger as Test.Logger) as Boolean {
    // findPlace() liest _names und _places ueber denselben Index - kippt die
    // Reihenfolge, landen Koordinaten unter dem falschen Namen.
    var got = WaypointWriter.deviceNames(["Eins", "Zwei", "Drei"] as Array<String>);
    Test.assertEqual(got[0], "Eins");
    Test.assertEqual(got[1], "Zwei");
    Test.assertEqual(got[2], "Drei");
    return true;
}

// -- Wegpunkte ---------------------------------------------------------------

(:test)
function waypointsRoundTripThroughTheDevice(logger as Test.Logger) as Boolean {
    // Der eine Test, der die Geraete-API wirklich anfasst: schreiben,
    // wiederfinden, gezielt loeschen. Genau daran haengt die Zusage, dass ein
    // aus der Google-Liste entfernter Ort auch vom Edge verschwindet.
    //
    // Es bleibt bei einem einzigen Wegpunkt: der Simulator fasst zehn Orte und
    // bringt neun eigene mit. Der eine deckt trotzdem ab, worauf es ankommt -
    // dass der zurueckgelesene Name dem geschriebenen gleicht.
    Test.assert(WaypointWriter.available());
    WaypointWriter.removeAll();
    Test.assertEqual(WaypointWriter.presentNames().size(), 0);

    var wanted = WaypointWriter.shorten("Restaurant Hanedan");
    Test.assert(WaypointWriter.add(wanted, 50.73788, 7.08179));

    var present = WaypointWriter.presentNames();
    Test.assertEqual(present.size(), 1);
    Test.assertEqual(present[0], wanted);
    Test.assert(!Util.contains(present, "Restaurant Hanedan"));

    // Was eine andere Liste noch beansprucht, bleibt stehen.
    Test.assertEqual(
        WaypointWriter.removeNames([wanted] as Array<String>, [wanted] as Array<String>), 0);
    Test.assertEqual(WaypointWriter.presentNames().size(), 1);

    Test.assertEqual(
        WaypointWriter.removeNames([wanted] as Array<String>, [] as Array<String>), 1);
    Test.assertEqual(WaypointWriter.presentNames().size(), 0);

    WaypointWriter.removeAll();
    Test.assertEqual(WaypointWriter.presentNames().size(), 0);
    return true;
}

(:test)
function accentedNamesSurviveTheDevice(logger as Test.Logger) as Boolean {
    // Die Zusicherung, an der alles haengt, mit Akzenten: was shorten()
    // liefert, kommt unveraendert zurueck - sonst findet der namensbasierte
    // Abgleich den Wegpunkt nie wieder.
    //
    // Den urspruenglichen Fehler kann dieser Test nicht nachstellen: der
    // Simulator schneidet bei fuenfzehn Zeichen, nicht bei fuenfzehn Bytes,
    // und nimmt "REWE Frederic C" mit seinen siebzehn Bytes unveraendert an.
    // Genau deshalb ist der Fehler hier nie aufgefallen. Was bleibt, ist die
    // Richtung: fuenfzehn Bytes sind nie mehr als fuenfzehn Zeichen, also
    // haelt dieser Weg unter beiden Regeln.
    Test.assert(WaypointWriter.available());
    WaypointWriter.removeAll();
    Test.assertEqual(WaypointWriter.presentNames().size(), 0);

    var e = eAcute();
    var wanted = WaypointWriter.shorten("REWE Fr" + e + "d" + e + "ric Cahon");
    Test.assertEqual(WaypointWriter.byteLength(wanted), WaypointWriter.NAME_LIMIT);
    Test.assert(WaypointWriter.add(wanted, 50.73244, 7.07526));

    var present = WaypointWriter.presentNames();
    Test.assertEqual(present.size(), 1);
    Test.assertEqual(present[0], wanted);

    WaypointWriter.removeAll();
    Test.assertEqual(WaypointWriter.presentNames().size(), 0);
    return true;
}

// -- Storage -----------------------------------------------------------------

(:test)
function storeRoundTripsListState(logger as Test.Logger) as Boolean {
    SyncStore.forgetAll();
    SyncStore.saveList("aa", "h1", ["Eins", "Zwei"] as Array<String>);
    SyncStore.saveList("bb", "h2", ["Drei"] as Array<String>);

    Test.assertEqual(SyncStore.listHash("aa"), "h1");
    Test.assertEqual(SyncStore.listNames("aa").size(), 2);
    Test.assertEqual(SyncStore.syncedCount(), 3);

    // Was andere Listen beanspruchen, darf beim Loeschen nicht mitgehen.
    var others = SyncStore.namesExcept("aa");
    Test.assertEqual(others.size(), 1);
    Test.assertEqual(others[0], "Drei");

    SyncStore.dropList("aa");
    Test.assertEqual(SyncStore.listNames("aa").size(), 0);
    Test.assertEqual(SyncStore.syncedCount(), 1);

    SyncStore.forgetAll();
    return true;
}

(:test)
function storeIgnoresForeignValues(logger as Test.Logger) as Boolean {
    SyncStore.forgetAll();
    SyncStore.set(SyncStore.listKey("aa"), { "h" => 7, "n" => ["Ok", 42, null] });
    Test.assertEqual(SyncStore.listHash("aa"), "");
    var names = SyncStore.listNames("aa");
    Test.assertEqual(names.size(), 1);
    Test.assertEqual(names[0], "Ok");

    SyncStore.forgetAll();
    return true;
}
