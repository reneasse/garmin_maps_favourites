// Liest oeffentlich geteilte Google-Maps-Listen mit einem Headless-Browser aus.
//
// Warum so umstaendlich: Google bietet fuer gespeicherte Listen keine API. Die
// haeufig zitierte Regex-Loesung auf dem rohen HTML bricht ab etwa 20 Eintraegen,
// weil die Liste nachgeladen wird - deshalb hier ein echter Browser, der das
// Panel scrollt, bis nichts mehr dazukommt.
//
// Das ist und bleibt undokumentiertes Terrain. Wenn Google das Markup aendert,
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

const PLACE_LINK = 'a[href*="/maps/place/"]';
const FEED = 'div[role="feed"]';

// Ohne Einwilligung zeigt Google statt der Karte eine Zwischenseite. Am
// Arbeitsplatz klickt man sie einmal weg, auf dem Runner kommt sie bei jedem
// Lauf: frische IP, kein Profil, kein Cookie. Der Klickpfad in acceptConsent()
// bleibt als Rueckfallebene, aber verlassen sollte man sich auf ihn nicht -
// die Zwischenseite sieht je nach Region anders aus. Diese Cookies nehmen sie
// vorweg. Auch das ist undokumentiert und kann brechen; dann meldet
// scrapeList() wenigstens, auf welcher Seite es haengengeblieben ist.
const CONSENT_COOKIES = [
  { name: 'CONSENT', value: 'YES+', domain: '.google.com', path: '/' },
  { name: 'SOCS', value: 'CAESHAgBEhIaAB', domain: '.google.com', path: '/' }
];

// -- reine Logik -------------------------------------------------------------

/**
 * Koordinaten aus einem Google-Maps-Ortslink.
 *
 * Bevorzugt wird das !3d/!4d-Paar: das ist der Ort selbst. Das @-Paar in der
 * URL ist nur der Kartenmittelpunkt und kann daneben liegen - es dient hier als
 * Rueckfallebene, wenn das erste Muster fehlt.
 */
export function coordsFromHref(href) {
  const url = String(href ?? '');
  const exact = url.match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/);
  if (exact) return { lat: Number(exact[1]), lon: Number(exact[2]) };

  const centre = url.match(/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
  if (centre) return { lat: Number(centre[1]), lon: Number(centre[2]) };

  return null;
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

/** Rohe Treffer aus dem DOM -> {name, lat, lon}, ohne die unbrauchbaren. */
export function toPlaces(hits) {
  const places = [];
  for (const hit of hits ?? []) {
    const name = String(hit?.name ?? '').replace(/\s+/g, ' ').trim();
    if (name.length === 0) continue;
    const coords = coordsFromHref(hit?.href);
    if (coords == null) continue;
    places.push({ name, lat: coords.lat, lon: coords.lon });
  }
  return places;
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
 * "Nichts gefunden" allein ist beim naechsten Bruch wertlos - es sagt nicht,
 * ob eine ganz andere Seite kam oder nur das Markup gewandert ist. Titel, URL,
 * die Zahl der Links und ihre haeufigsten Formen sagen das. Absichtlich nur
 * Struktur, keine Inhalte: die Listen sind nicht oeffentlich, und ein Log ist
 * es unter Umstaenden schon.
 */
async function describePage(page) {
  const seen = await page.evaluate((feedSelector) => {
    const shapes = new Map();
    for (const a of document.querySelectorAll('a[href]')) {
      // Nur das Geruest des Pfades, nie die Ortsangabe dahinter - auch das
      // @-Segment nicht, das sind Koordinaten.
      const path = a.getAttribute('href').replace(/^https?:\/\/[^/]+/, '');
      const key = path.split('/').slice(0, 3)
        .map((segment) => (segment.startsWith('@') ? '@...' : segment))
        .join('/');
      shapes.set(key, (shapes.get(key) ?? 0) + 1);
    }
    return {
      links: document.querySelectorAll('a[href]').length,
      feed: document.querySelector(feedSelector) != null,
      shapes: [...shapes.entries()]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 6)
        .map(([key, n]) => `${key} (${n})`)
    };
  }, FEED);

  return `Seite "${await page.title()}" (${page.url()}), ${seen.links} Links, `
    + `role=feed ${seen.feed ? 'vorhanden' : 'fehlt'}`
    + (seen.shapes.length > 0 ? `, haeufigste Pfade: ${seen.shapes.join(', ')}` : '');
}

/** Scrollt das Listenpanel, bis die Anzahl der Eintraege stehen bleibt. */
async function scrollFeed(page, { rounds = 60, settle = 3, pause = 1200 } = {}) {
  let last = -1;
  let stable = 0;

  for (let i = 0; i < rounds && stable < settle; i++) {
    const count = await page.evaluate(({ link, feed: feedSelector }) => {
      const feed = document.querySelector(feedSelector)
        ?? document.querySelector('div[role="main"]')
        ?? document.scrollingElement;
      if (feed) feed.scrollTop = feed.scrollHeight;
      return document.querySelectorAll(link).length;
    }, { link: PLACE_LINK, feed: FEED });

    if (count === last) {
      stable++;
    } else {
      stable = 0;
      last = count;
    }
    await page.waitForTimeout(pause);
  }
  return last;
}

export async function scrapeList(url, { locale = 'de-DE', timeout = 60000, headless = true } = {}) {
  const { chromium } = await import('playwright');
  // Ohne das Flag setzt Chromium navigator.webdriver, und Google liefert
  // Automaten gern eine andere Seite aus als Besuchern. Der User-Agent unten
  // allein reicht dafuer nicht.
  const browser = await chromium.launch({
    headless,
    args: ['--disable-blink-features=AutomationControlled']
  });
  try {
    const context = await browser.newContext({
      locale,
      viewport: { width: 1280, height: 1600 },
      // Der Standard sagt "HeadlessChrome"; darauf antwortet Google gern mit
      // einer abgespeckten Seite ohne die Ortslinks, die hier gebraucht
      // werden. Die Version kommt aus dem Browser selbst, damit sie mitwaechst.
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        + `(KHTML, like Gecko) Chrome/${browser.version()} Safari/537.36`
    });
    await context.addCookies(CONSENT_COOKIES);
    const page = await context.newPage();
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
    await acceptConsent(page);

    // Auf das Panel warten, nicht auf die Ortslinks: Google haengt die
    // Eintraege nachtraeglich hinein, und ein Teil davon kommt erst beim
    // Scrollen. Wer hier auf Ortslinks wartet, wartet unter Umstaenden auf
    // etwas, das ohne das Scrollen weiter unten nie erscheint - und
    // scrollFeed() kaeme nach dieser Zeile nie an die Reihe.
    try {
      await page.waitForSelector(`${FEED}, ${PLACE_LINK}`, { timeout });
    } catch {
      throw new Error(`Kein Listenpanel nach ${timeout} ms - ${await describePage(page)}`);
    }
    await scrollFeed(page);

    const hits = await page.evaluate((selector) =>
      Array.from(document.querySelectorAll(selector)).map((a) => ({
        name: a.getAttribute('aria-label') ?? a.textContent ?? '',
        href: a.href
      })), PLACE_LINK);

    const places = toPlaces(hits);
    if (places.length === 0) {
      throw new Error('Keine Orte gefunden - Liste nicht oeffentlich oder Markup '
        + `geaendert. ${await describePage(page)}`);
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
