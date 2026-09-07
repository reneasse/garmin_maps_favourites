import Toybox.Lang;
using Toybox.Background;
using Toybox.System;
using Toybox.Time;

//! Hintergrundlauf des Abgleichs.
//!
//! Connect IQ kennt keinen Haken fuer "Geraet eingeschaltet" oder "aus dem
//! Standby geweckt". Was es gibt, ist ein wiederkehrendes Temporal Event - und
//! ein faelliges Event feuert sofort, sobald das Geraet wieder laeuft. Genau
//! das ist hier der Ersatz fuer den Start-Trigger.
//!
//! Regel wie im Schwesterprojekt: jeder Pfad erreicht genau ein exit().
(:background)
class SyncService extends System.ServiceDelegate {

    hidden var _engine as SyncEngine or Null = null;
    hidden var _exited as Boolean = false;

    function initialize() {
        ServiceDelegate.initialize();
    }

    function onTemporalEvent() as Void {
        Settings.load();
        if (!Settings.autoSync) {
            exitNow(SyncStore.STAT_IDLE);
            return;
        }
        var engine = new SyncEngine(true, method(:onSyncChanged));
        _engine = engine;
        // start() meldet Vorbedingungsfehler ueber finish() - und damit ueber
        // onSyncChanged, wo der exit() bereits passiert ist.
        engine.start(false);
        if (!_exited && !engine.isRunning()) {
            exitNow(status());
        }
    }

    //! Wird bei jedem Fortschritt gerufen; erst wenn der Automat steht, ist der
    //! Lauf vorbei.
    function onSyncChanged() as Void {
        var engine = _engine;
        if (engine == null || engine.isRunning()) { return; }
        exitNow(status());
    }

    hidden function status() as Number {
        var st = SyncStore.status();
        var code = st["e"];
        if (code instanceof Number) { return code; }
        return SyncStore.STAT_IDLE;
    }

    hidden function exitNow(code as Number) as Void {
        if (_exited) { return; }
        _exited = true;
        // Der eigentliche Zustand liegt in Storage; hier reicht ein Signal,
        // damit der Vordergrund weiss, dass es etwas Neues gibt.
        Background.exit({ "e" => code, "s" => Time.now().value() });
    }
}
