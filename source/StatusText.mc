import Toybox.Lang;
using Toybox.WatchUi;

//! Uebersetzt die Zustandscodes aus SyncStore in Text fuer die Anzeige.
//!
//! Eigene Codes bleiben unter 100. Alles darueber ist ein woertlicher
//! HTTP-Status, alles Negative ein Connect-IQ-Transportfehler - beide werden
//! roh mit ausgegeben, weil die Zahl beim Suchen der Ursache mehr hilft als
//! ein geglaetteter Satz. -402 heisst zum Beispiel: Antwort zu gross.
module StatusText {

    function forStatus(code as Number, blocked as Number) as String {
        if (code == SyncStore.STAT_OK) { return res(Rez.Strings.StatDone); }
        if (code == SyncStore.STAT_IDLE) { return res(Rez.Strings.StatIdle); }
        if (code == SyncStore.STAT_NO_URL) { return res(Rez.Strings.StatNoUrl); }
        if (code == SyncStore.STAT_NO_CONN) { return res(Rez.Strings.StatNoConn); }
        if (code == SyncStore.STAT_NO_LISTS) { return res(Rez.Strings.StatNoLists); }
        if (code == SyncStore.STAT_BAD_DATA) { return res(Rez.Strings.StatBadData); }
        if (code == SyncStore.STAT_EMPTY) { return res(Rez.Strings.StatEmpty); }
        if (code == SyncStore.STAT_BULK) { return res(Rez.Strings.StatBulkBlocked); }
        if (code == SyncStore.STAT_NO_API) { return res(Rez.Strings.StatBadData); }
        if (code == SyncStore.STAT_PARTIAL) { return res(Rez.Strings.StatPartial); }
        if (code == SyncStore.STAT_TOO_MANY) {
            return Lang.format(res(Rez.Strings.StatTooMany),
                [blocked.toString(), Settings.maxFavourites.toString()]);
        }
        return Lang.format(res(Rez.Strings.StatHttp), [code.toString()]);
    }

    function res(id as ResourceId) as String {
        return WatchUi.loadResource(id) as String;
    }
}
