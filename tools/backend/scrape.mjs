// Liest oeffentlich geteilte Google-Maps-Listen mit einem Headless-Browser aus.
//
// Warum so umstaendlich: Google bietet fuer gespeicherte Listen keine API.
//
// Frueher standen die Eintraege als <a href=".../maps/place/..."> im Panel, und
// die Koordinaten liessen sich aus dem Link ziehen. Das ist vorbei. Eine
// geteilte Liste rendert heute ganz ohne Anker - der Eintrag ist ein <div> mit
// Klick-Handler, die Seite hat null <a>-Elemente, und im DOM steht ueberhaupt
// keine Koordinate mehr. Wer auf 'a[href*="/maps/place/"]' wartet, wartet
// endlos auf etwas, das es nicht mehr gibt.
//
// Die Orte kommen stattdessen ueber zwei Requests, deren Antworten hier
// mitgelesen werden. Das ist kein schoenerer Weg, aber der einzige verbliebene:
//
// - /maps/preview/entitylist/getlist ist die Liste selbst: alle Eintraege mit
//   Namen und Koordinaten, auch gesetzte Pins ("49°25'25.8"N 7°34'08.0"E").
// - /search?tbm=map loest beim Scrollen die Eintraege zu Google-Orten auf. Ein
//   Pin ist kein Google-Ort und kommt dort nie vor - wer nur diese Antwort
//   liest, verliert jeden Pin der Liste, ohne dass es auffaellt.
//
// Das ist und bleibt undokumentiertes Terrain. Wenn Google das Format aendert,
// findet dieses Skript nichts mehr. Von hier aus ist das nicht von einer
// bewusst geleerten Liste zu unterscheiden - deshalb entscheidet nicht dieses
// Skript, sondern die Sperre in build.mjs: eine vorher gefuellte Liste, die
// leer zurueckkommt, wird nur mit ausdruecklichem Zugestaendnis veroeffentlicht.
//
// Gefaehrlicher als leer ist halb: das Nachladen bleibt stecken, und es kommen
// 37 von 42 Orten - bei jedem Lauf andere. Das Geraet loescht dann Favoriten
// und legt sie beim naechsten Lauf wieder an. Deshalb wird die Anzahl, die
// Google im Kopf der Liste anzeigt, mitgelesen und an build.mjs gereicht.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONFIG = path.join(HERE, 'lists.config.json');
const CACHE_DIR = path.join(HERE, '.cache');
const CACHE = path.join(CACHE_DIR, 'raw.json');

// Der Request, der die Orte bringt. Dieselbe Adresse bedient auch die normale
// Kartensuche - praktisch, denn daran laesst sich das Auslesen unten gegen
// viele Treffer pruefen, ohne eine fremde Liste anzufassen.
const PAYLOAD_URL = '/search?tbm=map';

// Der Request, der die Liste selbst bringt - samt Pins, siehe oben.
const LIST_URL = '/maps/preview/entitylist/getlist';

// Ohne Einwilligung zeigt Google statt der Karte eine Zwischenseite ("Bevor
// Sie zu Google weitergehen"). Am Arbeitsplatz klickt man sie einmal weg, im
// Skript kommt sie bei jedem Lauf: frisches Profil, kein Cookie. Ohne diese
// beiden Cookies endet der Lauf nachweislich dort - mit ihnen laedt die Liste.
// Der Klickpfad in acceptConsent() bleibt als Rueckfallebene.
const CONSENT_COOKIES = [
  { name: 'CONSENT', value: 'YES+', domain: '.google.com', path: '/' },
  { name: 'SOCS', value: 'CAESHAgBEhIaAB', domain: '.google.com', path: '/' }
];

// -- reine Logik -------------------------------------------------------------

/**
 * Zerlegt aneinandergehaengte JSON-Objekte auf oberster Ebene.
 *
 * Die Antwort ist keine einzelne JSON-Datei, sondern eine Kette von Stuecken
 * der Form {"c":..,"d":".."}. JSON.parse ueber das Ganze scheitert daran.
 * Anfuehrungszeichen und Escapes muessen dabei mitgezaehlt werden, sonst
 * beendet eine geschweifte Klammer *innerhalb* eines Textes das Stueck.
 */
export function splitJsonObjects(text) {
  const source = typeof text === 'string' ? text : '';
  const objects = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escaped = false;

  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; continue; }
    if (ch === '{') {
      if (depth === 0) start = i;
      depth++;
      continue;
    }
    if (ch === '}' && depth > 0) {
      depth--;
      if (depth === 0 && start >= 0) {
        objects.push(source.slice(start, i + 1));
        start = -1;
      }
    }
  }
  return objects;
}

/**
 * Die Nutzlast aus der Antwort: die "d"-Felder aller Stuecke, aneinander
 * gehaengt und um Googles XSSI-Vorspann ")]}'" erleichtert.
 */
export function unwrapPayload(body) {
  return splitJsonObjects(body)
    .map((chunk) => {
      try {
        const value = JSON.parse(chunk).d;
        return typeof value === 'string' ? value : '';
      } catch {
        return '';
      }
    })
    .join('')
    .replace(/^\)\]\}'\n?/, '');
}

/**
 * Orte aus einer Antwort des Nachlade-Requests.
 *
 * Die Nutzlast ist ein tief verschachteltes Array ohne Feldnamen. Nach Position
 * zu greifen waere aussichtslos - jede Verschiebung bei Google zoege stillen
 * Unsinn nach sich. Gesucht wird deshalb nach einer Form, die fuer einen Ort
 * kennzeichnend ist: das Koordinatenpaar, unmittelbar gefolgt von Googles
 * Ortskennung (0x..:0x..) und dem Anzeigenamen.
 *
 * Die Kennung dazwischen ist der Grund, warum das trennscharf bleibt: dieselbe
 * [null,null,lat,lon]-Form steht auch an Fotos und Rezensionen, aber nur beim
 * Ort folgt ihr die Kennung. Ohne sie kaemen Fotostandorte als Favoriten mit.
 */
const PLACE = /\[null,null,(-?\d+\.\d+),(-?\d+\.\d+)\],"(0x[0-9a-f]+:0x[0-9a-f]+)","((?:[^"\\]|\\.)*)"/g;

export function placesFromPayload(body) {
  const payload = unwrapPayload(body);
  const places = [];
  const pattern = new RegExp(PLACE.source, 'g');

  let match;
  while ((match = pattern.exec(payload)) !== null) {
    let name;
    try {
      // Der Name steht als JSON-Text da und kann Escapes enthalten.
      name = JSON.parse(`"${match[4]}"`);
    } catch {
      continue;
    }
    const lat = Number(match[1]);
    const lon = Number(match[2]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    places.push({ id: match[3], name, lat, lon });
  }
  return places;
}

/**
 * Eintraege aus der Antwort von getlist, der Liste selbst.
 *
 * Kein Stueckwerk wie bei /search, sondern ein einzelnes Array hinter dem
 * XSSI-Vorspann. Ein Eintrag beginnt mit [null,[..,[null,null,lat,lon]
 * - bei einem Google-Ort gefolgt von dessen Kennung als zwei vorzeichenbehaftete
 * Dezimalzahlen ["5158439181059265237","-6426135483264128656"], bei einem Pin
 * ohne - und dann dem Namen. Gesucht wird wieder nach dieser Form statt nach
 * Position.
 *
 * Die Kennung wird in die Schreibweise von /search umgerechnet (0x..:0x..),
 * damit dedupe() denselben Ort aus beiden Antworten als einen erkennt. Ein Pin
 * hat keine und laeuft dort ueber Name und Koordinaten.
 */
const VALUE = String.raw`(?:null|-?\d+(?:\.\d+)?|"(?:[^"\\]|\\.)*")`;
const NUMBER = String.raw`(-?\d+(?:\.\d+)?)`;
const LIST_ENTRY = new RegExp(String.raw`\[null,\[${VALUE}(?:,${VALUE})*,`
  + String.raw`\[null,null,${NUMBER},${NUMBER}\](?:,\["(-?\d+)","(-?\d+)"\])?\],`
  + String.raw`"((?:[^"\\]|\\.)*)"`, 'g');

/** Vorzeichenbehaftete 64-Bit-Dezimalzahl -> Hex, wie in 0x..:0x.. */
function hexId(decimal) {
  return `0x${BigInt.asUintN(64, BigInt(decimal)).toString(16)}`;
}

export function placesFromList(body) {
  const source = typeof body === 'string' ? body : '';
  const places = [];
  const pattern = new RegExp(LIST_ENTRY.source, 'g');

  let match;
  while ((match = pattern.exec(source)) !== null) {
    let name;
    try {
      name = JSON.parse(`"${match[5]}"`);
    } catch {
      continue;
    }
    const lat = Number(match[1]);
    const lon = Number(match[2]);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
    const id = match[3] == null ? undefined : `${hexId(match[3])}:${hexId(match[4])}`;
    places.push({ id, name, lat, lon });
  }
  return places;
}

/**
 * Share-Links aus der Umgebung, als JSON `{"Listenname": "https://..."}`.
 *
 * Braucht man, sobald das Repository oeffentlich ist: die Links selbst oeffnen
 * die Google-Listen und gehoeren dann nicht in eine eingecheckte Datei,
 * sondern in ein Secret. Fehlt die Variable, gilt die url aus der Konfiguration.
 */
export function parseUrlOverrides(raw) {
  if (raw == null || String(raw).trim().length === 0) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed == null || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    const out = {};
    for (const [name, url] of Object.entries(parsed)) {
      if (typeof url === 'string' && url.length > 0) out[name] = url;
    }
    return out;
  } catch {
    return {};
  }
}

/** Ist das ueberhaupt ein benutzbarer Link, oder noch der Platzhalter? */
export function usableUrl(url) {
  const value = String(url ?? '');
  if (!value.startsWith('http')) return false;
  return !value.includes('REPLACE_ME');
}

/**
 * Die Anzahl, die Google im Kopf einer geteilten Liste anzeigt ("42 Orte").
 *
 * Nur die deutsche Form, passend zur festen Locale in scrapeList(): ein
 * englisches "place" stuende auch in franzoesischen Adressen ("3 place de la
 * Gare") und lieferte eine falsche Soll-Zahl - und eine zu hohe sperrt die
 * Liste. Gezaehlt wird der erste Treffer, der Kopf steht vor den Eintraegen.
 * Nichts gefunden ist null, nicht 0: eine unbekannte Zahl prueft nichts.
 */
const LIST_COUNT = /(?:^|[^\d.,])(\d{1,5})\s+(?:Orte|Ort)\b/;

export function countFromText(text) {
  const match = LIST_COUNT.exec(String(text ?? ''));
  return match ? Number(match[1]) : null;
}

/** Doppelte weg - dieselbe Antwort kann mehrfach durchlaufen. */
export function dedupe(places) {
  const seen = new Set();
  const out = [];
  for (const place of places ?? []) {
    const key = place?.id ?? `${place?.name}|${place?.lat}|${place?.lon}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ name: place.name, lat: place.lat, lon: place.lon });
  }
  return out;
}

// -- Browser -----------------------------------------------------------------

async function acceptConsent(page) {
  // Der Consent-Dialog kommt je nach Region als eigene Seite oder als Overlay.
  const candidates = [
    'button[aria-label*="Alle akzeptieren" i]',
    'button[aria-label*="Accept all" i]',
    'form[action*="consent"] button',
    'button:has-text("Alle akzeptieren")',
    'button:has-text("Accept all")'
  ];
  for (const selector of candidates) {
    const button = page.locator(selector).first();
    try {
      // waitFor statt isVisible: isVisible fragt sofort und ohne zu warten -
      // solange die Zwischenseite noch baut, sagt es reihum bei jedem
      // Kandidaten "nein", und der Dialog bleibt stehen.
      await button.waitFor({ state: 'visible', timeout: 1500 });
      await button.click({ timeout: 5000 });
      await page.waitForLoadState('domcontentloaded');
      return true;
    } catch {
      // Dieser Kandidat passt nicht - der naechste vielleicht.
    }
  }
  return false;
}

/**
 * Kurzbeschreibung der Seite fuer den Fehlerfall.
 *
 * "Nichts gefunden" allein ist beim naechsten Bruch wertlos - es sagt nicht, ob
 * eine andere Seite kam oder nur das Format gewandert ist. Absichtlich nur
 * Struktur, keine Inhalte: die Listen sind nicht oeffentlich, und ein Log ist
 * es unter Umstaenden schon.
 *
 * Kein Wort mehr ueber den Anmeldelink: den zeigt Google auf jeder Seite jedem,
 * der nicht angemeldet ist. Er hat hier einmal zur falschen Faehrte gefuehrt.
 */
async function describePage(page, { responses, places }) {
  const seen = await page.evaluate(() => {
    const main = document.querySelector('div[role="main"]');
    return {
      panel: main != null,
      // Ob ueberhaupt Eintraege gerendert sind, ohne sie zu zitieren.
      textLength: (main?.innerText ?? '').trim().length
    };
  });

  return `Seite "${await page.title()}" (${page.url()}), `
    + `Panel ${seen.panel ? 'vorhanden' : 'fehlt'}, ${seen.textLength} Zeichen Text, `
    + `${responses} passende Antworten mit ${places} Orten`;
}

/**
 * Die Soll-Zahl aus dem Kopf der Liste, oder null.
 *
 * Der Kopf baut sich nicht zwingend mit dem Panel auf - deshalb kurz warten,
 * statt einmal zu fragen und eine unbekannte Zahl hinzunehmen.
 */
async function readListCount(page, timeout = 10000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const text = await page.evaluate(() =>
      (document.querySelector('div[role="main"]') ?? document.body).innerText ?? '');
    const count = countFromText(text);
    if (count != null || Date.now() >= deadline) return count;
    await page.waitForTimeout(500);
  }
}

/**
 * Laeuft im Browser: scrollt den Container, der die Eintraege traegt, ans Ende
 * - oder mit `back` ein Stueck zurueck - und gibt dessen Mitte zurueck (fuer
 * das Mausrad), oder null.
 *
 * Der Container ist nicht div[role="main"] selbst - das scrollt nicht, und
 * scrollTop darauf zu setzen bewirkt nichts. Bei der Kartensuche ist es
 * div[role="feed"], bei einer geteilten Liste gibt es das nicht. Dort scrollt
 * ein namenloses <div> irgendwo darin. Gesucht wird es deshalb an dem, was es
 * ausmacht: overflow-y erlaubt Scrollen, und es gibt etwas zu scrollen. Von
 * mehreren Kandidaten gewinnt der mit dem meisten Inhalt.
 *
 * Bleibt das aus, kommt nur die erste Antwort durch - genau 20 Orte, egal wie
 * lang die Liste ist.
 */
function scrollPanel(back) {
  const scrollable = (el) => {
    const { overflowY } = getComputedStyle(el);
    return (overflowY === 'auto' || overflowY === 'scroll')
      && el.scrollHeight > el.clientHeight + 10;
  };

  let panel = document.querySelector('div[role="feed"]');
  if (panel == null || !scrollable(panel)) {
    const root = document.querySelector('div[role="main"]') ?? document.body;
    panel = [root, ...root.querySelectorAll('div')]
      .filter(scrollable)
      .sort((a, b) => b.scrollHeight - a.scrollHeight)[0] ?? null;
  }
  if (panel == null) return null;

  panel.scrollTop = back ? Math.max(0, panel.scrollTop - 1500) : panel.scrollHeight;
  const box = panel.getBoundingClientRect();
  return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
}

/**
 * Scrollt das Panel, bis nichts mehr dazukommt.
 *
 * Gezaehlt wird, was aus den Antworten gefallen ist, nicht was im DOM steht:
 * die Orte kommen ueber das Netz, und beim Scrollen laedt Google nach. Bei der
 * Kartensuche kam die erste Antwort sogar voellig ohne Orte - ohne Scrollen
 * bliebe es dabei.
 *
 * `missing()` sagt, wie viele Orte laut Kopf der Liste noch fehlen (null:
 * unbekannt). Fehlen noch welche, reichen drei ruhige Runden nicht als Beweis
 * fuer "zu Ende": so blieb es bei zwei Antworten und 37 von 42 Orten. Dann
 * wird laenger gewartet, und jede zweite Runde geht es ein Stueck zurueck -
 * steht der Container schon am Ende, loest erst ein erneutes Hinunterscrollen
 * das Nachladen wieder aus.
 */
async function scrollUntilSettled(page, count, {
  missing = () => null, rounds = 60, settle = 3, patience = 10, pause = 1200
} = {}) {
  let last = -1;
  let stable = 0;

  for (let i = 0; i < rounds; i++) {
    const left = missing();
    if (left === 0) break;
    if (stable >= (left == null ? settle : patience)) break;

    const back = left != null && stable % 2 === 1;
    const target = await page.evaluate(scrollPanel, back);
    // Zusaetzlich das Mausrad ueber dem Panel: Google haengt das Nachladen
    // teils an Wheel-Events statt an die Scrollposition, und so scrollt auch
    // ein Nutzer.
    if (target) {
      await page.mouse.move(target.x, target.y);
      await page.mouse.wheel(0, back ? -1500 : 4000);
    }
    await page.waitForTimeout(pause);

    const now = count();
    if (now === last) {
      stable++;
    } else {
      stable = 0;
      last = now;
    }
  }
  return last;
}

/**
 * Ein Durchgang mit frischem Profil. Haengt die gefundenen Orte an `collected`
 * an - das sammelt ueber alle Durchgaenge - und gibt
 * { expected, responses, unreadable, diagnosis } zurueck.
 */
async function scrapeOnce(browser, url, collected, { locale, timeout, expected }) {
  const context = await browser.newContext({
    locale,
    viewport: { width: 1280, height: 1600 },
    // Der Standard sagt "HeadlessChrome". Die Version kommt aus dem Browser
    // selbst, damit sie mitwaechst.
    userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      + `(KHTML, like Gecko) Chrome/${browser.version()} Safari/537.36`
  });
  try {
    await context.addCookies(CONSENT_COOKIES);
    const page = await context.newPage();

    // Mitlesen, bevor navigiert wird - die erste Antwort kommt sofort. Die
    // Bodies werden asynchron gelesen; was noch laeuft, wird unten abgewartet,
    // sonst schliesst der Browser darueber und die Orte fallen still weg.
    let responses = 0;
    let unreadable = 0;
    const pending = new Set();
    page.on('response', (response) => {
      const fromList = response.url().includes(LIST_URL);
      if (!fromList && !response.url().includes(PAYLOAD_URL)) return;
      responses++;
      const read = response.text()
        .then((body) => {
          collected.push(...(fromList ? placesFromList(body) : placesFromPayload(body)));
        })
        // Body nicht mehr lesbar (Navigation dazwischen). Gezaehlt, nicht
        // verschwiegen: genau so gehen Orte verloren.
        .catch(() => { unreadable++; })
        .finally(() => pending.delete(read));
      pending.add(read);
    });

    await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
    await acceptConsent(page);

    // Auf das Panel warten, nicht auf einzelne Eintraege: die stehen als <div>
    // ohne stabiles Merkmal da. Ob wirklich etwas kam, entscheidet unten die
    // Zahl der Orte - nicht ein Selektor, der nichts garantiert.
    try {
      await page.waitForSelector('div[role="main"]', { timeout });
    } catch {
      throw new Error(`Kein Panel nach ${timeout} ms - `
        + `${await describePage(page, { responses, places: collected.length })}`);
    }

    const shown = expected ?? await readListCount(page);
    const missing = () => (shown == null ? null : Math.max(0, shown - dedupe(collected).length));
    await scrollUntilSettled(page, () => collected.length, { missing });
    await Promise.allSettled([...pending]);

    const diagnosis = collected.length === 0
      ? await describePage(page, { responses, places: 0 })
      : null;
    return { expected: shown, responses, unreadable, diagnosis };
  } finally {
    await context.close();
  }
}

/**
 * -> { places, expected, diagnosis, responses, unreadable, attempts }.
 *
 * `expected` ist die Anzahl laut Kopf der Liste, oder null, wenn sie nicht zu
 * lesen war. Ob `places` dazu passt, entscheidet build.mjs. Hier wird nur so
 * lange nachgefasst, bis es passt: fehlen Orte, folgt ein neuer Durchgang mit
 * frischem Profil, und die Ergebnisse werden vereinigt. Alle Durchgaenge
 * liegen Minuten auseinander und sehen dieselbe Liste - was einer gefunden
 * hat, gehoert dazu, auch wenn der naechste es verpasst. Ohne Soll-Zahl bleibt
 * es bei einem Durchgang, wie bisher.
 *
 * `diagnosis` beschreibt die Seite, wenn keine Orte kamen, und ist sonst null.
 * `responses` zaehlt die mitgelesenen Antworten - bleibt es bei einer, hat das
 * Nachladen nicht gegriffen. `unreadable` zaehlt Antworten, deren Inhalt nicht
 * mehr zu lesen war.
 *
 * Null Orte sind hier kein Fehler mehr: eine geleerte Liste sieht genauso aus
 * wie ein gebrochener Scraper, und nur build.mjs kennt den vorigen Stand, an
 * dem sich das entscheiden laesst. Geworfen wird nur, wenn in keinem
 * Durchgang eine Liste geladen hat.
 */
export async function scrapeList(url, {
  locale = 'de-DE', timeout = 60000, headless = true, attempts = 3
} = {}) {
  const { chromium } = await import('playwright');
  // Ohne das Flag setzt Chromium navigator.webdriver, und Google liefert
  // Automaten gern eine andere Seite aus als Besuchern.
  const browser = await chromium.launch({
    headless,
    args: ['--disable-blink-features=AutomationControlled']
  });
  try {
    const collected = [];
    let expected = null;
    let responses = 0;
    let unreadable = 0;
    let diagnosis = null;
    let loaded = false;
    let lastError = null;
    let tries = 0;

    while (tries < attempts) {
      tries++;
      try {
        const run = await scrapeOnce(browser, url, collected, { locale, timeout, expected });
        loaded = true;
        expected = run.expected;
        responses += run.responses;
        unreadable += run.unreadable;
        diagnosis = run.diagnosis;
      } catch (error) {
        lastError = error;
        continue;
      }
      if (expected == null || dedupe(collected).length >= expected) break;
    }
    if (!loaded) throw lastError;

    return { places: dedupe(collected), expected, diagnosis, responses, unreadable, attempts: tries };
  } finally {
    await browser.close();
  }
}

// -- Ausfuehrung -------------------------------------------------------------

async function main() {
  const config = JSON.parse(await readFile(CONFIG, 'utf8'));
  const overrides = parseUrlOverrides(process.env.LIST_URLS);
  const lists = {};

  for (const list of config.lists ?? []) {
    const url = overrides[list.name] ?? list.url;
    if (!usableUrl(url)) {
      const hint = `Kein Share-Link fuer "${list.name}" - weder in lists.config.json noch im Secret LIST_URLS`;
      lists[list.name] = { ok: false, error: hint };
      console.error(hint);
      continue;
    }
    try {
      const { places, expected, diagnosis, responses, unreadable, attempts } = await scrapeList(url);
      lists[list.name] = { ok: true, places, expected };
      const soll = expected == null ? ' (Anzahl der Liste nicht lesbar)' : ` von ${expected}`;
      const lost = unreadable > 0 ? `, ${unreadable} nicht lesbar` : '';
      console.log(`${list.name}: ${places.length}${soll} Orte aus ${responses} Antworten${lost}, `
        + `${attempts} ${attempts === 1 ? 'Durchgang' : 'Durchgaenge'}`);
      if (diagnosis) {
        // Leer ist erlaubt, aber verdaechtig - bricht der Scraper, ist das hier
        // die einzige Stelle, an der man es sieht.
        console.warn(`${list.name}: keine Orte - Liste leer, nicht oeffentlich `
          + `oder Format geaendert. ${diagnosis}`);
      }
    } catch (error) {
      // Ein Fehlschlag ist kein Abbruch: die uebrigen Listen sollen trotzdem
      // durchlaufen, und build.mjs behaelt fuer diese hier den alten Stand.
      lists[list.name] = { ok: false, error: error.message };
      console.error(`${list.name}: ${error.message}`);
    }
  }

  await mkdir(CACHE_DIR, { recursive: true });
  await writeFile(CACHE, JSON.stringify({
    scrapedAt: Math.floor(Date.now() / 1000),
    lists
  }, null, 2));

  const failed = Object.values(lists).filter((entry) => !entry.ok).length;
  if (failed > 0) { process.exitCode = 1; }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
