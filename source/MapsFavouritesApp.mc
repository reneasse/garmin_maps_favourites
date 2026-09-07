import Toybox.Lang;
using Toybox.Application;
using Toybox.Background;
using Toybox.System;
using Toybox.Time;
using Toybox.WatchUi;

//! Maps Favourites - spiegelt Orte aus Google-Maps-Listen in die Favoriten des
//! Edge.
//!
//! Die Klasse ist (:background) annotiert, damit der Hintergrunddienst starten
//! kann; alles, was ihr Konstruktor beruehrt, muss dieselbe Annotation tragen.
(:background)
class MapsFavouritesApp extends Application.AppBase {

    hidden var _view as MainView or Null = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary or Null) as Void {
        Settings.load();
        scheduleSync();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new MainView();
        _view = view;
        return [view, new MainDelegate(view)];
    }

    function onSettingsChanged() as Void {
        Settings.load();
        scheduleSync();
        var v = _view;
        if (v != null) {
            v.reload();
            WatchUi.requestUpdate();
        }
    }

    //! Der Hintergrunddienst schreibt seinen Zustand direkt in Storage. Laufen
    //! beide Prozesse gleichzeitig, meldet Connect IQ das hierueber.
    function onStorageChanged() as Void {
        var v = _view;
        if (v != null) {
            v.reload();
            WatchUi.requestUpdate();
        }
    }

    function getServiceDelegate() as [System.ServiceDelegate] {
        return [new SyncService()];
    }

    //! Der Dienst liefert nur ein Signal; die Daten stehen schon in Storage.
    function onBackgroundData(data as Application.PersistableType) as Void {
        var v = _view;
        if (v != null) {
            v.reload();
            WatchUi.requestUpdate();
        }
    }

    //! (Neu-)Registrierung des wiederkehrenden Ereignisses. Garmin erzwingt
    //! fuenf Minuten Mindestabstand und lehnt kuerzere Werte rundheraus ab,
    //! deshalb clampt Settings den konfigurierten Wert.
    hidden function scheduleSync() as Void {
        if (!(Toybox has :Background)) { return; }
        try {
            if (!Settings.autoSync) {
                if (Background.getTemporalEventRegisteredTime() != null) {
                    Background.deleteTemporalEvent();
                }
                return;
            }
            Background.registerForTemporalEvent(new Time.Duration(Settings.syncIntervalMin * 60));
        } catch (e) {
            // Hintergrundrecht verweigert oder Intervall abgelehnt - die App
            // bleibt bedienbar, der Abgleich laeuft dann nur von Hand.
        }
    }
}
