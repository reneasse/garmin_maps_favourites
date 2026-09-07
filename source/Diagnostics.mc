import Toybox.Lang;
using Toybox.PersistedContent;
using Toybox.System;
using Toybox.WatchUi;

//! Was steht wirklich auf dem Geraet?
//!
//! Der Statusbildschirm zeigt nur, was die App sich gemerkt hat. Bleiben die
//! Favoriten in der Geraetenavigation unsichtbar, muss man eine Ebene tiefer
//! schauen, und dafuer gibt es genau eine aussagekraeftige Gegenueberstellung:
//!
//!   getAppWaypoints()  der Bestand dieser App
//!   getWaypoints()     der gesamte Wegpunktspeicher des Geraets
//!
//! Stehen in der zweiten Liste auch die von Hand angelegten Favoriten des
//! Nutzers, ist es derselbe Speicher wie Navigation -> Favoriten - dann liegt
//! es an der Anzeige des Geraets, nicht am Schreiben. Enthaelt sie dagegen nur
//! die App-eigenen Eintraege, sind es zwei getrennte Ablagen, und der ganze
//! Ansatz ueber PersistedContent traegt nicht.
module Diagnostics {

    //! Ortseintrag als [id, name].
    const W_ID = 0;
    const W_NAME = 1;

    function menu() as WatchUi.Menu2 {
        var m = new WatchUi.Menu2({ :title => Rez.Strings.MnuDiag });

        var own = appIds();
        var all = allWaypoints();

        m.addItem(line(Rez.Strings.DiagApp, own.size().toString()));
        m.addItem(line(Rez.Strings.DiagAll, all.size().toString()));
        m.addItem(line(Rez.Strings.DiagStored, SyncStore.syncedCount().toString()));
        m.addItem(line(Rez.Strings.DiagDevice, deviceLine()));

        for (var i = 0; i < all.size(); i++) {
            var entry = all[i] as Array;
            var mine = containsId(own, entry[W_ID] as Number);
            m.addItem(new WatchUi.MenuItem(
                entry[W_NAME] as String,
                mine ? Rez.Strings.DiagOwn : Rez.Strings.DiagForeign,
                null, null));
        }
        return m;
    }

    function line(label as ResourceId, value as String) as WatchUi.MenuItem {
        return new WatchUi.MenuItem(label, value, null, null);
    }

    //! Ids der Wegpunkte, die diese App angelegt hat.
    function appIds() as Array<Number> {
        var out = [] as Array<Number>;
        if (!WaypointWriter.available()) { return out; }
        try {
            var it = PersistedContent.getAppWaypoints();
            for (var wp = it.next(); wp != null; wp = it.next()) {
                out.add(wp.getId());
            }
        } catch (e) {
            // Ein abgebrochener Durchlauf zeigt eben weniger - die Diagnose
            // darf daran nicht selbst scheitern.
        }
        return out;
    }

    //! Alle Wegpunkte des Geraets als [id, name] - auch die fremden.
    function allWaypoints() as Array {
        var out = [] as Array;
        if (!(Toybox has :PersistedContent)) { return out; }
        if (!(PersistedContent has :getWaypoints)) { return out; }
        try {
            var it = PersistedContent.getWaypoints();
            for (var wp = it.next(); wp != null; wp = it.next()) {
                out.add([wp.getId(), wp.getName()] as Array);
            }
        } catch (e) {
        }
        return out;
    }

    function containsId(list as Array<Number>, id as Number) as Boolean {
        for (var i = 0; i < list.size(); i++) {
            if (list[i] == id) { return true; }
        }
        return false;
    }

    //! Teilenummer und Firmware - beides gehoert in jede Fehlermeldung, weil
    //! sich das Verhalten des Ortsspeichers zwischen Modellen unterscheidet.
    function deviceLine() as String {
        var s = System.getDeviceSettings();
        var part = "?";
        var fw = "?";
        if (s has :partNumber) {
            var p = s.partNumber;
            if (p instanceof String) { part = p; }
        }
        if (s has :firmwareVersion) {
            var v = s.firmwareVersion;
            if (v instanceof Array && v.size() >= 2) {
                fw = v[0].toString() + "." + v[1].toString();
            }
        }
        return part + " / " + fw;
    }
}

//! Die Diagnose ist eine reine Anzeige: jede Eingabe fuehrt zurueck.
class DiagnosticsDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
