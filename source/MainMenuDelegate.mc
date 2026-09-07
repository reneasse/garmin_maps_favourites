import Toybox.Lang;
using Toybox.WatchUi;

//! Hauptmenue: abgleichen, Listen waehlen, aufraeumen.
class MainMenuDelegate extends WatchUi.Menu2InputDelegate {

    hidden var _view as MainView;

    function initialize(view as MainView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :sync) {
            selectSync();
        } else if (id == :lists) {
            selectLists();
        } else if (id == :removeAll) {
            selectRemoveAll();
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }

    //! Hing der letzte Lauf an der Loeschsperre, wird hier nachgefragt statt
    //! einfach wieder in dieselbe Sperre zu laufen.
    hidden function selectSync() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        if (_view.statusCode() == SyncStore.STAT_BULK && _view.blockedCount() > 0) {
            var msg = Lang.format(StatusText.res(Rez.Strings.CfmBulkDelete),
                [_view.blockedCount().toString()]);
            WatchUi.pushView(
                new WatchUi.Confirmation(msg),
                new ConfirmDelegate(method(:syncWithBulk)),
                WatchUi.SLIDE_UP);
            return;
        }
        _view.startSync(false);
    }

    function syncWithBulk() as Void {
        _view.startSync(true);
    }

    hidden function selectLists() as Void {
        var catalog = SyncStore.catalog();
        if (catalog == null || catalog.size() == 0) {
            // Ohne Katalog gibt es nichts auszuwaehlen. Ein Abgleich holt ihn,
            // auch wenn noch keine Liste gewaehlt ist.
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _view.startSync(false);
            return;
        }

        var selection = SyncStore.selection();
        var menu = new WatchUi.CheckboxMenu({ :title => Rez.Strings.MnuListsTitle });
        for (var i = 0; i < catalog.size(); i++) {
            var entry = catalog[i];
            if (!(entry instanceof Array) || entry.size() <= Feed.C_PAGES) { continue; }
            var id = entry[Feed.C_ID];
            var name = entry[Feed.C_NAME];
            var count = entry[Feed.C_COUNT];
            if (!(id instanceof String) || !(name instanceof String)) { continue; }
            var sub = Lang.format(StatusText.res(Rez.Strings.MnuPlaces),
                [(count instanceof Number) ? count.toString() : "?"]);
            menu.addItem(new WatchUi.CheckboxMenuItem(
                name, sub, id, Util.contains(selection, id), null));
        }
        WatchUi.pushView(menu, new ListPickerDelegate(_view, selection), WatchUi.SLIDE_LEFT);
    }

    hidden function selectRemoveAll() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        WatchUi.pushView(
            new WatchUi.Confirmation(StatusText.res(Rez.Strings.CfmRemoveAll)),
            new ConfirmDelegate(method(:removeAll)),
            WatchUi.SLIDE_UP);
    }

    //! Entfernt nur, was diese App angelegt hat - fremde Favoriten sind fuer
    //! remove() ohnehin unerreichbar. Der gemerkte Zustand muss mit weg, sonst
    //! haelt der naechste Abgleich die Wegpunkte fuer noch vorhanden.
    function removeAll() as Void {
        WaypointWriter.removeAll();
        SyncStore.forgetAll();
        SyncStore.saveStatus(SyncStore.STAT_IDLE, 0, 0);
        _view.reload();
        WatchUi.requestUpdate();
    }
}
