import Toybox.Lang;
using Toybox.WatchUi;

//! Auswahl der Listen direkt am Geraet.
//!
//! Der Dienst liefert die verfuegbaren Listen im Katalog; hier wird angehakt,
//! was auf das Geraet soll. Die Auswahl liegt im Storage, nicht in den
//! App-Einstellungen - so laesst sie sich unterwegs ohne Telefon aendern.
//!
//! Gespeichert wird erst beim Verlassen: ein versehentlicher Haken, der gleich
//! wieder weggenommen wird, loest keinen Abgleich aus.
class ListPickerDelegate extends WatchUi.Menu2InputDelegate {

    hidden var _view as MainView;
    hidden var _selection as Array<String>;
    //! Je nach Geraet kann onDone und onBack nacheinander kommen; zweimal
    //! popView wuerde auch den Statusbildschirm mitnehmen.
    hidden var _committed as Boolean = false;

    function initialize(view as MainView, selection as Array<String>) {
        Menu2InputDelegate.initialize();
        _view = view;
        _selection = selection;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof String)) { return; }
        if (!(item instanceof WatchUi.CheckboxMenuItem)) { return; }

        if (item.isChecked()) {
            if (!Util.contains(_selection, id)) { _selection.add(id); }
        } else {
            _selection = without(_selection, id);
        }
    }

    function onBack() as Void {
        commit();
    }

    function onDone() as Void {
        commit();
    }

    hidden function commit() as Void {
        if (_committed) { return; }
        _committed = true;
        SyncStore.saveSelection(_selection);
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        // Abwaehlen ist eine ausdrueckliche Entscheidung: der folgende Lauf
        // raeumt die Wegpunkte der abgewaehlten Listen ohne Rueckfrage weg.
        _view.startSync(false);
    }

    hidden function without(list as Array<String>, id as String) as Array<String> {
        var out = [] as Array<String>;
        for (var i = 0; i < list.size(); i++) {
            if (!list[i].equals(id)) { out.add(list[i]); }
        }
        return out;
    }
}
