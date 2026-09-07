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
// Die Orte kommen stattdessen ueber einen Nachlade-Request (/search?tbm=map),
// dessen Antwort Name und Koordinaten traegt. Diese Antwort wird hier
// mitgelesen. Das ist kein schoenerer Weg, aber der einzige verbliebene.
//
// Das ist und bleibt undokumentiertes Terrain. Wenn Google das Format aendert,
// findet dieses Skript nichts mehr und meldet einen Fehler. Genau dafuer gibt
// es die Sperren in build.mjs: ein Fehlschlag veroeffentlicht nichts, statt
// eine leere Liste auszuliefern.

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
 * Scrollt das Panel, bis nichts mehr dazukommt.
 *
 * Gezaehlt wird, was aus den Antworten gefallen ist, nicht was im DOM steht:
 * die Orte kommen ueber das Netz, und beim Scrollen laedt Google nach. Bei der
 * Kartensuche kam die erste Antwort sogar voellig ohne Orte - ohne Scrollen
 * bliebe es dabei.
 */
async function scrollUntilSettled(page, count, { rounds = 60, settle = 3, pause = 1200 } = {}) {
  let last = -1;
  let stable = 0;

  for (let i = 0; i < rounds && stable < settle; i++) {
    await page.evaluate(() => {
      const panel = document.querySelector('div[role="feed"]')
        ?? document.querySelector('div[role="main"]')
        ?? document.scrollingElement;
      if (panel) panel.scrollTop = panel.scrollHeight;
    });
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

export async function scrapeList(url, { locale = 'de-DE', timeout = 60000, headless = true } = {}) {
  const { chromium } = await import('playwright');
  // Ohne das Flag setzt Chromium navigator.webdriver, und Google liefert
  // Automaten gern eine andere Seite aus als Besuchern.
  const browser = await chromium.launch({
    headless,
    args: ['--disable-blink-features=AutomationControlled']
  });
  try {
    const context = await browser.newContext({
      locale,
      viewport: { width: 1280, height: 1600 },
      // Der Standard sagt "HeadlessChrome". Die Version kommt aus dem Browser
      // selbst, damit sie mitwaechst.
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        + `(KHTML, like Gecko) Chrome/${browser.version()} Safari/537.36`
    });
    await context.addCookies(CONSENT_COOKIES);
    const page = await context.newPage();

    // Mitlesen, bevor navigiert wird - die erste Antwort kommt sofort.
    const collected = [];
    let responses = 0;
    page.on('response', async (response) => {
      if (!response.url().includes(PAYLOAD_URL)) return;
      responses++;
      try {
        collected.push(...placesFromPayload(await response.text()));
      } catch {
        // Body nicht mehr lesbar (Navigation dazwischen) - die naechste Antwort
        // bringt dieselben Orte noch einmal.
      }
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

    await scrollUntilSettled(page, () => collected.length);

    const places = dedupe(collected);
    if (places.length === 0) {
      throw new Error('Keine Orte gefunden - Liste nicht oeffentlich oder Format '
        + `geaendert. ${await describePage(page, { responses, places: 0 })}`);
    }
    return places;
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
      const places = await scrapeList(url);
      lists[list.name] = { ok: true, places };
      console.log(`${list.name}: ${places.length} Orte`);
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
