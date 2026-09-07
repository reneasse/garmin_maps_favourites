import Toybox.Lang;
using Toybox.WatchUi;

//! Eingaben auf dem Statusbildschirm.
//!
//! Jede Bedienhandlung fuehrt ins Menue - die Zielgeraete reichen vom
//! Tasten-Edge bis zum reinen Touchgeraet, und ein einziger Einstieg ist
//! ueberall auffindbar. Der Abgleich steht dort als erster Eintrag.
class MainDelegate extends WatchUi.BehaviorDelegate {

    hidden var _view as MainView;

    function initialize(view as MainView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onMenu() as Boolean {
        showMenu();
        return true;
    }

    function onSelect() as Boolean {
        showMenu();
        return true;
    }

    function onTap(event as WatchUi.ClickEvent) as Boolean {
        showMenu();
        return true;
    }

    hidden function showMenu() as Void {
        var menu = new WatchUi.Menu2({ :title => Rez.Strings.MnuTitle });
        menu.addItem(new WatchUi.MenuItem(
            Rez.Strings.MnuSyncNow, null, :sync, null));
        menu.addItem(new WatchUi.MenuItem(
            Rez.Strings.MnuLists, null, :lists, null));
        menu.addItem(new WatchUi.MenuItem(
            Rez.Strings.MnuRemoveAll, null, :removeAll, null));
        menu.addItem(new WatchUi.MenuItem(
            Rez.Strings.MnuDiag, null, :diag, null));
        WatchUi.pushView(menu, new MainMenuDelegate(_view), WatchUi.SLIDE_UP);
    }
}
