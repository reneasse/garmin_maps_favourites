import Toybox.Lang;
using Toybox.WatchUi;

//! Ja/Nein-Rueckfrage, die bei Zustimmung eine uebergebene Methode aufruft.
//!
//! Beide Rueckfragen der App loeschen Favoriten - einmal auf Wunsch des
//! Nutzers, einmal weil der Abgleich ungewoehnlich viele Loeschungen sah.
class ConfirmDelegate extends WatchUi.ConfirmationDelegate {

    hidden var _onYes as Lang.Method;

    function initialize(onYes as Lang.Method) {
        ConfirmationDelegate.initialize();
        _onYes = onYes;
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            _onYes.invoke();
        }
        return true;
    }
}
