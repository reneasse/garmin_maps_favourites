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
      if (await button.isVisible({ timeout: 1500 })) {
        await button.click({ timeout: 5000 });
        await page.waitForLoadState('domcontentloaded');
        return;
      }
    } catch {
      // Dieser Kandidat passt nicht - der naechste vielleicht.
    }
  }
}

/** Scrollt das Listenpanel, bis die Anzahl der Eintraege stehen bleibt. */
async function scrollFeed(page, { rounds = 60, settle = 3, pause = 1200 } = {}) {
  let last = -1;
  let stable = 0;

  for (let i = 0; i < rounds && stable < settle; i++) {
    const count = await page.evaluate((selector) => {
      const feed = document.querySelector('div[role="feed"]')
        ?? document.querySelector('div[role="main"]')
        ?? document.scrollingElement;
      if (feed) feed.scrollTop = feed.scrollHeight;
      return document.querySelectorAll(selector).length;
    }, PLACE_LINK);

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
  const browser = await chromium.launch({ headless });
  try {
    const context = await browser.newContext({
      locale,
      viewport: { width: 1280, height: 1600 }
    });
    const page = await context.newPage();
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
    await acceptConsent(page);
    await page.waitForSelector(PLACE_LINK, { timeout });
    await scrollFeed(page);

    const hits = await page.evaluate((selector) =>
      Array.from(document.querySelectorAll(selector)).map((a) => ({
        name: a.getAttribute('aria-label') ?? a.textContent ?? '',
        href: a.href
      })), PLACE_LINK);

    const places = toPlaces(hits);
    if (places.length === 0) {
      throw new Error('Keine Orte gefunden - Liste nicht oeffentlich oder Markup geaendert');
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
