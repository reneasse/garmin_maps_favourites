# Maps Favourites — Google-Maps-Listen in den Edge-Favoriten

**Wie kommen die Orte, die man am Rechner in Google Maps gesammelt hat, ohne Abtippen auf den Radcomputer — und wieder herunter, wenn man sie dort löscht?**

```
┌──────────────────────────┐
│      Maps Favourites     │
│                          │
│                          │
│         Aktuell          │
│                          │
│                          │
│        vor 12 min        │
│                          │
│   2 Listen · 34 Favoriten│
│                          │
│                          │
│     Menü für Optionen    │
└──────────────────────────┘
```

Die App spiegelt benannte Google-Maps-Listen in die Standortliste des Edge. Neue Orte kommen dazu, entfernte verschwinden wieder — und zwar **nur** die, die diese App selbst angelegt hat. Eigene Favoriten des Nutzers sind für sie technisch unerreichbar.

---

## Wie das Ganze zusammenhängt

```
Google Maps          GitHub Actions          GitHub Pages         Edge
(geteilte Liste) ──▶ Playwright-Scraper ──▶ docs/*.json ──▶ Handy ──▶ Favoriten
                     täglich + manuell       Katalog + Seiten        (Wegpunkte)
```

Der Umweg ist keine Bequemlichkeit, sondern notwendig:

- **Google hat für gespeicherte Listen keine API.** Nur öffentlich geteilte Listen sind überhaupt lesbar, und nur durch Auslesen der Seite. Die verbreitete Regex-Lösung auf dem rohen HTML bricht ab etwa 20 Einträgen ab, weil die Liste nachgeladen wird — deshalb ein echter Browser, der scrollt.
- **Das Edge kann das nicht selbst.** Connect IQ verarbeitet JSON-Antworten bis etwa 16 kB, ein Hintergrundprozess hat 32 kB Heap. HTML von Google zu parsen ist dort ausgeschlossen. Der Dienst liefert deshalb vorverdautes, seitenweises JSON.

---

## Unterstützte Geräte

Edge 540, 550, 840, 850, 1040, 1050 — alle mit Connect IQ 6.0.0. Der App-Typ ist `watch-app` (Device App), zu finden im Menü unter *Connect IQ Apps*.

Speicherbudget laut Gerätedefinition: 1 MB für die App, **32 kB für den Hintergrunddienst**. Die zweite Zahl prägt den halben Entwurf.

---

## Der JSON-Contract

Die App kennt genau zwei Dateiformen unter der konfigurierten Basis-URL.

**Katalog** — `<base>index.json`

```json
{"v":1,"t":1757260800,"l":[{"i":"4647e0af","n":"Cafes","c":30,"h":"82b60ded","p":2}]}
```

| Feld | Bedeutung |
|---|---|
| `v` | Schema-Version, muss `1` sein — sonst verweigert die App die Antwort |
| `t` | Erzeugungszeit, epoch-Sekunden |
| `i` | Listen-Id, zugleich der Verzeichnisname |
| `n` | Anzeigename in der Listenauswahl |
| `c` | Anzahl Orte, für die Obergrenzenprüfung |
| `h` | Inhalts-Hash |
| `p` | Anzahl Seiten |

**Seite** — `<base>l/<id>/<n>.json`

```json
{"i":"4647e0af","h":"82b60ded","p":0,"n":2,"e":[["Cafe Central",48.13721,11.57559]]}
```

`e` sind die Orte als `[name, lat, lon]`. Ein Eintrag wiegt rund 42 Byte, eine Seite mit 25 Einträgen etwa 1,1 kB — weit unter der 16-kB-Grenze und verträglich für den 32-kB-Heap.

Zwei Felder tragen mehr Gewicht, als sie aussehen:

- **`h` im Katalog** ist die Abkürzung: stimmt der Hash mit dem gespeicherten überein, wird die Liste gar nicht erst geladen. Ein unveränderter Sync kostet genau einen Request.
- **`h` in der Seite** muss zum Katalog passen. Läuft der Backend-Build mitten in einem Sync durch, käme sonst Seite 0 vom alten und Seite 1 vom neuen Stand — der Abgleich hätte Lücken und würde löschen.

---

## Einrichtung

### 1. Listen in Google Maps öffentlich teilen

Liste öffnen → *Teilen* → Link erzeugen. Nur öffentlich geteilte Listen sind auslesbar.

### 2. Listennamen eintragen

`tools/backend/lists.config.json` enthält nur die Namen — die Share-Links kommen aus einem Secret, damit sie nicht im Repository stehen:

```json
{
  "pageSize": 25,
  "nameMaxLength": 20,
  "lists": [
    { "name": "Cafes" },
    { "name": "Aussichtspunkte" }
  ]
}
```

`name` ist frei wählbar, muss exakt zum Schlüssel im Secret passen und erscheint so in der Auswahl am Gerät. Für lokale Läufe darf ersatzweise ein `"url"`-Feld daneben stehen.

### 3. Zwei Repository-Secrets anlegen

*Settings → Secrets and variables → Actions → New repository secret*

| Secret | Inhalt |
|---|---|
| `LIST_SALT` | Eine beliebige zufällige Zeichenkette, **die nie wieder geändert wird** |
| `LIST_URLS` | `{"Cafes":"https://maps.app.goo.gl/…","Aussichtspunkte":"https://maps.app.goo.gl/…"}` |

`LIST_SALT` geht in jede Listen-Id ein. Ändert es sich, heißen alle Listen anders, der vorher veröffentlichte Katalog wird nicht mehr wiedergefunden, und die Auswahl am Gerät zeigt ins Leere. `build.mjs` bricht deshalb ab, wenn das Secret fehlt, statt stillschweigend neue Ids zu vergeben.

### 4. Pages einschalten

*Settings → Pages* → **Deploy from a branch**, Branch `main`, Ordner `/docs`.

> **Pages gibt es im kostenlosen Tarif nur für öffentliche Repositories.** Ist das Repository privat, braucht es GitHub Pro — oder man schaltet es öffentlich. Weil die Share-Links im Secret liegen und nicht in der Konfiguration, gibt ein öffentliches Repository den Zugang zu den Google-Listen nicht preis.

### 5. Workflow starten

*Actions → sync-lists → Run workflow*. Danach steht der Katalog unter `https://<user>.github.io/<repo>/index.json`.

> **Zur Vertraulichkeit:** Die veröffentlichten JSON-Dateien sind öffentlich lesbar. Die Listen-Ids sind mit `LIST_SALT` gehasht, damit die URLs nicht zu erraten sind — das ist Verschleierung, keine Sicherheit. Wer die URL kennt, sieht die Orte. Für wirklich vertrauliche Orte gehört der Dienst hinter eine Authentifizierung.

### 6. App einrichten

Basis-URL in den App-Einstellungen eintragen (Garmin Connect oder Express), dann am Gerät *Menü → Listen wählen*. Beim ersten Aufruf ohne Katalog holt die App ihn zuerst; danach steht die Auswahl bereit.

---

## Einstellungen

| Property | Standard | Bedeutung |
|---|---|---|
| `serviceUrl` | leer | Basis-URL der veröffentlichten Daten |
| `autoSync` | `true` | Hintergrunddienst aktiv |
| `syncIntervalMin` | `60` | 5 … 720, wird geclampt (Garmin erzwingt fünf Minuten) |
| `maxFavourites` | `150` | Obergrenze über alle gewählten Listen; Edge fasst etwa 200 |
| `allowBulkDelete` | `false` | Löschsperre abschalten |

Die **Listenauswahl steht bewusst nicht hier**, sondern im Gerätemenü — so lässt sie sich unterwegs ohne Telefon ändern.

---

## Automatik — und was Connect IQ nicht kann

Gewünscht war: synchronisieren beim Start des Geräts und beim Aufwachen aus dem Standby. **Diese Haken gibt es in Connect IQ nicht.** `Background.registerForWakeEvent` meint die Weckzeit der Schlafaufzeichnung bei Uhren, nicht das Aufwachen eines Radcomputers.

Was es gibt, kommt nah heran: ein wiederkehrendes Temporal Event, mindestens alle fünf Minuten. Ein fälliges Event feuert laut Garmin-Dokumentation sofort, sobald das Gerät wieder läuft — praktisch also kurz nach dem Einschalten. Dazu kommt ein Abgleich beim Öffnen der App.

---

## Wie der Abgleich funktioniert

```
IDLE → Katalog holen → je gewählter Liste:
          Hash unverändert? → überspringen
          sonst Seiten holen → Differenz → anwenden
       → Aufräumen (nur Vordergrund) → fertig
```

Der Zustand liegt in `Application.Storage`, **ein Key je Liste** (`w<id>`) mit Hash und den geschriebenen Namen. Der Hintergrundprozess muss so nie alle ~200 Namen gleichzeitig laden, und jeder Wert bleibt weit unter der 8-kB-Grenze von Storage.

Vier Entscheidungen, die man dem Code sonst nicht ansieht:

**Verglichen wird über Gerätenamen, nicht über die aus der Google-Liste.** Der Ortsspeicher schneidet bei **15 Zeichen** ab — auf Edge 540, 840, 1040 und 1050 nachgemessen; bis dahin kommt jeder Name unverändert zurück, samt Umlauten, Akzenten und Leerzeichen am Ende. Geschrieben wird deshalb schon der gekürzte Name (`WaypointWriter.shorten()`), und Soll wie Ist stehen von der Differenzbildung an in dieser Form. Fallen zwei Orte auf denselben Rumpf, bekommt der zweite eine Kennziffer (`~2`) — für den namensbasierten Abgleich wären sie sonst derselbe Wegpunkt.

Wird das versäumt, bricht die App auf eine Art zusammen, die man ihr nicht ansieht: der volle Name geht hinein, der gekürzte kommt zurück, **kein einziger** Wegpunkt findet sich wieder, die Liste gilt als unvollständig, es wird nichts gemerkt — und die Aufräumrunde hält den gerade geschriebenen Bestand für verwaist und löscht ihn. Sichtbar wird das als `Teilweise übertragen · 0 Favoriten` bei leerer Gerätenavigation.

**Aufgeräumt wird nur nach einem sauberen Lauf.** Die Waisen-Suche am Ende vergleicht den Gerätebestand mit dem, was sich die App gemerkt hat. Blieb eine Liste unfertig, ist das Gemerkte kleiner als der tatsächliche Bestand — die Differenz wäre dann kein Waisenkind, sondern genau das eben Geschriebene. Liegenbleiben kostet nichts: der nächste vollständige Lauf räumt auf.

**`saveWaypoint()` lügt, wenn die Standortliste voll ist** — es meldet weiter Erfolg, und der Wegpunkt fehlt trotzdem. Im Simulator ist das reproduzierbar: er nimmt nur neun App-Wegpunkte an und quittiert jeden weiteren mit Erfolg. Deshalb entscheidet ausschließlich der zurückgelesene Bestand, ob eine Liste als fertig gilt. Ohne diese Prüfung speichert die App den Hash, meldet „Aktuell" und hat die Hälfte der Orte nie geschrieben. Ist etwas offen geblieben, steht `Teilweise übertragen` und der nächste Lauf macht weiter.

**Der Vordergrund rekonziliert, der Hintergrund nicht.** Einmal pro Vordergrundlauf wird der tatsächliche Bestand eingelesen: von Hand gelöschte Favoriten kommen zurück, verwaiste Einträge abgewählter Listen verschwinden. Im Hintergrund wäre dieser Durchlauf zu teuer — dort zählt nur der inkrementelle Vergleich, und der nächste Vordergrundlauf korrigiert.

**Unfertig wird nicht gemerkt, sondern vergessen.** Der Hintergrundlauf wendet höchstens 20 Änderungen an. Was liegen bleibt, landet nicht als Plan im Storage — stattdessen bleibt der Hash der Liste leer, und der nächste Lauf holt sie erneut und arbeitet den Rest ab. Ein Abbruch mitten drin hinterlässt so nie einen falschen, nur einen unfertigen Zustand.

**Namen sind der einzige Schlüssel.** `saveWaypoint()` gibt keine Id zurück, und `Waypoint` kennt kein `getLocation()`. Wiedergefunden wird ausschließlich über den Namen — deshalb macht das Backend die Namen eindeutig (` 2`, ` 3` …) und kürzt sie auf 15 Zeichen, bevor sie das Gerät je sieht. Die App kürzt trotzdem noch einmal selbst: sie muss auch mit älteren, längeren Daten richtig rechnen. Taucht auf dem Gerät ein `~2` auf, waren die Daten breiter als der Ortsspeicher.

### Sicherungen

Die Scraper-Kette hängt an undokumentiertem Google-HTML und wird irgendwann brechen. Sie darf dabei keine Favoriten mitnehmen:

1. **Backend:** eine Liste, die leer oder auf unter die Hälfte geschrumpft zurückkommt, wird nicht veröffentlicht — der alte Stand bleibt stehen, der Workflow schlägt laut fehl.
2. **App:** eine leer gewordene Liste bei vorher vorhandenem Bestand wird übersprungen, nicht angewendet.
3. **App:** mehr als `max(5, Bestand/2)` Löschungen auf einmal werden blockiert. Der Vordergrund fragt beim nächsten *Jetzt synchronisieren* nach, der Hintergrund lässt es. Abschaltbar über `allowBulkDelete`.
4. **App:** übersteigt die Summe der gewählten Listen `maxFavourites`, bricht der Sync **vor** der ersten Änderung ab.
5. Abwählen einer Liste ist eine ausdrückliche Nutzeraktion und umgeht Sicherung 3.
6. Ohne Telefonverbindung wird gar nicht erst angefragt.

---

## Bauen

```bash
SDK="$APPDATA/Garmin/ConnectIQ/Sdks/connectiq-sdk-win-9.2.0-2026-06-09-92a1605b2"
KEY=C:/Users/Rene/Documents/repos/garmin/developer_key

# Debug-Build fuer ein Geraet
"$SDK/bin/monkeyc.bat" -f monkey.jungle -o bin/MapsFavourites.prg -y $KEY -d edge1040 -w

# Im Simulator starten (Simulator vorher: "$SDK/bin/connectiq.bat")
"$SDK/bin/monkeydo.bat" bin/MapsFavourites.prg edge1040

# Unit-Tests
"$SDK/bin/monkeyc.bat" -f monkey.jungle -o bin/test.prg -y $KEY -d edge1040 -w --unit-test
"$SDK/bin/monkeydo.bat" bin/test.prg edge1040 /t

# Store-Paket
"$SDK/bin/monkeyc.bat" -e -f monkey.jungle -o bin/MapsFavourites.iq -y $KEY -w
```

In der Git-Bash frisst MSYS das `/t` und macht einen Windows-Pfad daraus — dort `MSYS_NO_PATHCONV=1` voranstellen.

Backend:

```bash
cd tools/backend
npm install
npx playwright install chromium
npm test                       # 14 Tests, kein Browser noetig
LIST_URLS='{"Cafes":"https://…"}' node scrape.mjs   # schreibt .cache/raw.json
LIST_SALT=… node build.mjs                          # schreibt docs/
```

Launcher-Icons neu erzeugen: `pwsh tools/make_icon.ps1` (schreibt PNG und `drawables.xml` je Gerätegröße: 35 / 40 / 56 / 68 px).

---

## Dateien

| Datei | Aufgabe |
|---|---|
| [source/MapsFavouritesApp.mc](source/MapsFavouritesApp.mc) | Einstieg, Registrierung des Temporal Events, Rückkanal aus dem Hintergrund |
| [source/SyncEngine.mc](source/SyncEngine.mc) | Zustandsautomat: Katalog → Seiten → Differenz → Anwenden, samt Sperren |
| [source/SyncService.mc](source/SyncService.mc) | Hintergrunddienst, genau ein `exit()` je Pfad |
| [source/WaypointWriter.mc](source/WaypointWriter.mc) | Einziger Zugang zur Standortliste des Geräts |
| [source/SyncStore.mc](source/SyncStore.mc) | Storage-Schema und -Zugriff |
| [source/Feed.mc](source/Feed.mc) | Auswertung des JSON-Contracts, defensiv |
| [source/Settings.mc](source/Settings.mc) | App-Einstellungen mit Default und Clamping |
| [source/MainView.mc](source/MainView.mc) | Statusbildschirm |
| [source/MainDelegate.mc](source/MainDelegate.mc) | Eingaben auf dem Statusbildschirm |
| [source/MainMenuDelegate.mc](source/MainMenuDelegate.mc) | Hauptmenü |
| [source/Diagnostics.mc](source/Diagnostics.mc) | Wegpunktbestand des Geräts, App-eigen und fremd, nebeneinander |
| [source/ListPickerDelegate.mc](source/ListPickerDelegate.mc) | Listenauswahl am Gerät |
| [source/StatusText.mc](source/StatusText.mc) | Zustandscodes → Anzeigetext |
| [source/Util.mc](source/Util.mc) | Mengenvergleich, Koordinatenprüfung, Zeitformat |
| [source/Tests.mc](source/Tests.mc) | 24 Unit-Tests |
| [tools/backend/scrape.mjs](tools/backend/scrape.mjs) | Playwright-Scraper |
| [tools/backend/build.mjs](tools/backend/build.mjs) | Normalisierung, Paging, Hashing, Sperren |
| [.github/workflows/sync-lists.yml](.github/workflows/sync-lists.yml) | Cron und Veröffentlichung |

### Zustandscodes

Eigene Codes bleiben unter 100. Alles ab 100 ist ein wörtlicher HTTP-Status, alles Negative ein Connect-IQ-Transportfehler — `-402` heißt zum Beispiel „Antwort zu groß". Die Rohzahl steht in der Anzeige, weil sie beim Suchen der Ursache mehr hilft als ein geglätteter Satz.

---

## Status

**Getestet im Simulator (Edge 1040):**

- 27 Unit-Tests, davon einer gegen die echte Geräte-API: schreiben, wiederfinden, gezielt löschen über `PersistedContent` — inklusive der Regel, dass ein von einer zweiten Liste beanspruchter Name stehen bleibt, und der Zusicherung, dass der zurückgelesene Name dem geschriebenen gleicht.
- **Die Zeichengrenze des Ortsspeichers**, auf Edge 540, 840, 1040 und 1050 einzeln nachgemessen: 15 Zeichen, darüber wird wortlos abgeschnitten. Bis dahin ist der Weg durch den Speicher verlustfrei — geprüft mit Akzenten (`é`), Umlauten, `ß`, Leerzeichen am Ende und `~`.
- **Der komplette Weg, dreimal hintereinander gegen einen lokalen HTTP-Server:**
  1. Erster Lauf: Katalog + zwei Seiten geholt, 8 Orte als Wegpunkte geschrieben, beide Hashes gespeichert, Status *Aktuell*.
  2. Zweiter Lauf ohne Änderung: nur `index.json` — beide Listen per Hash übersprungen.
  3. **Ein Ort aus der Quelle entfernt:** nur `index.json` und die geänderte Seite geholt, der Wegpunkt vom Gerät verschwunden, die übrigen sieben unangetastet. Das ist die Kernzusage, und sie hält.
- Die Veröffentlichungssperre im Backend: eine von 30 auf 5 geschrumpfte Liste wurde abgelehnt, der alte Stand blieb stehen, der Lauf endete mit Exit-Code 1.
- Totalausfall des Scrapers bei bereits veröffentlichtem Stand: der Katalog blieb unverändert erhalten, Exit-Code 1 — das Gerät sieht unveränderte Hashes und rührt nichts an.
- Build für alle sechs Zielgeräte plus `.iq`-Store-Paket.
- 19 Node-Tests für Normalisierung, Paging, Hashing, Secret-Auswertung und die Sperre.

Der Simulator hält insgesamt **zehn** Orte und bringt neun eigene mit — für die App bleibt genau einer. Jeder weitere `saveWaypoint()`-Aufruf meldet Erfolg und schreibt nichts. Größere Mengen sind im Simulator deshalb nicht prüfbar, und der Geräte-Test kommt mit einem einzigen Wegpunkt aus.

**Nicht getestet:**

- **Der Scraper gegen eine echte Google-Liste.** Er ist gegen das aktuelle Markup geschrieben, aber ungeprüft — hier ist zuerst mit Nacharbeit zu rechnen. `node scrape.mjs` meldet klar, wenn er nichts findet, und die Sperre in `build.mjs` fängt den Rest ab.
- **Alles auf echter Hardware.** Offen: ob der Hintergrunddienst nach dem Einschalten wirklich zeitnah anläuft, ob die Zeichengrenze auf dem Gerät ebenfalls bei 15 liegt (der Simulator sagt das für alle vier geprüften Modelle), wie viele Wegpunkte das Gerät tatsächlich annimmt, und ob die App-eigenen Favoriten beim Deinstallieren mitgelöscht werden.
- Die anderen fünf Gerätemodelle jenseits des Builds.
- Der Hintergrunddienst selbst — im Simulator über *Simulation → Background Events → Temporal Event* auslösbar, hier nicht durchgespielt.

---

## Lizenz

Privates Projekt. Ortsdaten stammen aus den eigenen Google-Maps-Listen des Nutzers; die Auswertung geteilter Listen erfolgt ohne offizielle Schnittstelle und kann jederzeit brechen.
