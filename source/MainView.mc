import Toybox.Lang;
using Toybox.Graphics;
using Toybox.Time;
using Toybox.WatchUi;

//! Statusbildschirm: was zuletzt passiert ist und was gerade laeuft.
//!
//! Gezeichnet wird mit dc-Primitiven statt ueber ein Layout, wie in den
//! Schwesterprojekten - die Zielgeraete reichen von 246x322 bis 480x800, und
//! die paar Zeilen lassen sich relativ zur Hoehe zuverlaessiger setzen als
//! ueber sechs Layout-Varianten.
class MainView extends WatchUi.View {

    hidden var _engine as SyncEngine;
    hidden var _code as Number = SyncStore.STAT_IDLE;
    hidden var _when as Number = 0;
    hidden var _synced as Number = 0;
    hidden var _blocked as Number = 0;
    hidden var _lists as Number = 0;
    hidden var _autoStarted as Boolean = false;

    function initialize() {
        View.initialize();
        _engine = new SyncEngine(false, method(:onSyncChanged));
        reload();
    }

    function engine() as SyncEngine {
        return _engine;
    }

    function blockedCount() as Number {
        return _blocked;
    }

    function statusCode() as Number {
        return _code;
    }

    //! Zustand aus dem Storage nachladen - auch dann, wenn ihn der
    //! Hintergrunddienst geschrieben hat.
    function reload() as Void {
        var st = SyncStore.status();
        _code = st["e"] as Number;
        _when = st["t"] as Number;
        _synced = st["n"] as Number;
        _blocked = st["b"] as Number;
        _lists = SyncStore.selection().size();
    }

    function startSync(bulkOk as Boolean) as Void {
        _engine.start(bulkOk);
        WatchUi.requestUpdate();
    }

    function onSyncChanged() as Void {
        reload();
        WatchUi.requestUpdate();
    }

    //! Beim Oeffnen der App einmal abgleichen - das ist der zweite Ausloeser
    //! neben dem Hintergrunddienst.
    function onShow() as Void {
        if (_autoStarted) { return; }
        _autoStarted = true;
        if (Settings.configured() && SyncStore.selection().size() > 0) {
            _engine.start(false);
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.clear();

        var fTitle = (w >= 400) ? Graphics.FONT_SMALL : Graphics.FONT_XTINY;
        var fMain = (w >= 400) ? Graphics.FONT_LARGE
            : ((w >= 280) ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL);
        var fInfo = (w >= 400) ? Graphics.FONT_SMALL : Graphics.FONT_XTINY;

        var cx = w / 2;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        centre(dc, cx, h * 8 / 100, fTitle, StatusText.res(Rez.Strings.AppName));

        dc.setColor(headlineColour(), Graphics.COLOR_TRANSPARENT);
        centre(dc, cx, h * 33 / 100, fMain, headline());

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        centre(dc, cx, h * 56 / 100, fInfo, ageLine());
        centre(dc, cx, h * 68 / 100, fInfo, countLine());

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        centre(dc, cx, h * 88 / 100, fInfo, StatusText.res(Rez.Strings.LblHintMenu));
    }

    hidden function centre(
        dc as Graphics.Dc, x as Number, y as Number,
        font as Graphics.FontType, text as String
    ) as Void {
        dc.drawText(x, y, font, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    hidden function headline() as String {
        if (_engine.isRunning()) {
            var total = _engine.progressTotal();
            if (total == 0) { total = 1; }
            return Lang.format(StatusText.res(Rez.Strings.StatSyncing),
                [(_engine.progressDone() + 1).toString(), total.toString()]);
        }
        return StatusText.forStatus(_code, _blocked);
    }

    //! Rot nur fuer echte Fehler; blockierte Loeschungen sind eine Rueckfrage,
    //! kein Defekt.
    hidden function headlineColour() as Graphics.ColorType {
        if (_engine.isRunning()) { return Graphics.COLOR_BLACK; }
        if (_code == SyncStore.STAT_OK) { return Graphics.COLOR_DK_GREEN; }
        if (_code == SyncStore.STAT_IDLE || _code == SyncStore.STAT_PARTIAL) {
            return Graphics.COLOR_BLACK;
        }
        if (_code == SyncStore.STAT_BULK) { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_DK_RED;
    }

    hidden function ageLine() as String {
        if (_when <= 0) { return StatusText.res(Rez.Strings.LblNever); }
        var age = Time.now().value() - _when;
        if (age < 5) { return StatusText.res(Rez.Strings.LblNow); }
        // Eine Uhr, die zurueckspringt, darf keine negative Dauer erzeugen.
        if (age < 0) { age = 0; }
        return Lang.format(StatusText.res(Rez.Strings.LblAge), [Util.formatAge(age)]);
    }

    hidden function countLine() as String {
        var lists = Lang.format(StatusText.res(Rez.Strings.LblLists), [_lists.toString()]);
        var favs = Lang.format(StatusText.res(Rez.Strings.LblFavourites), [_synced.toString()]);
        return lists + "  ·  " + favs;
    }
}
