// Macht aus rohen Scraper-Ergebnissen die JSON-Dateien, die das Edge holt.
//
// Alles Wesentliche steckt in reinen Funktionen, damit der Teil, der ueber
// Loeschungen auf dem Geraet entscheidet, ohne Browser testbar bleibt.
//
// Ausgabe:
//   docs/index.json        Katalog
//   docs/l/<id>/<n>.json   Seiten zu je pageSize Orten
//
// Die wichtigsten Regeln stehen in guard() und completeness(): eine leer
// gewordene oder nur teilweise ausgelesene Liste wird nicht veroeffentlicht.
// Der Scraper haengt an undokumentiertem Google-HTML und wird irgendwann
// brechen - er darf dabei keine Favoriten mit ins Grab nehmen.

import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCHEMA_VERSION = 1;

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const DOCS = path.join(ROOT, 'docs');
const CACHE = path.join(HERE, '.cache', 'raw.json');
const CONFIG = path.join(HERE, 'lists.config.json');

// -- reine Logik -------------------------------------------------------------

/**
 * Laengster Anfang von `text`, der in `maxBytes` UTF-8-Bytes passt.
 *
 * Der Ortsspeicher des Edge zaehlt Bytes, nicht Zeichen - ein Akzent kostet
 * dort zwei. Wird nach Zeichen gekuerzt, schneidet das Geraet noch einmal
 * nach, gibt einen anderen Namen zurueck als den geschriebenen, und der
 * namensbasierte Abgleich findet den Wegpunkt nie wieder.
 *
 * Iteriert wird ueber Codepoints (`for...of`), nie ueber `slice`: ein Schnitt
 * mitten in einem Zeichen ergaebe einen Namen, den es so nirgends gibt.
 */
export function cutToBytes(text, maxBytes) {
  if (Buffer.byteLength(text, 'utf8') <= maxBytes) return text;
  let bytes = 0;
  let out = '';
  for (const ch of text) {
    const cost = Buffer.byteLength(ch, 'utf8');
    if (bytes + cost > maxBytes) break;
    bytes += cost;
    out += ch;
  }
  return out;
}

/** Zwei Buchstaben statt einem - was im Deutschen ausgeschrieben wird. */
const FOLD_PAIRS = {
  'Ä': 'Ae', 'Ö': 'Oe', 'Ü': 'Ue', 'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ß': 'ss',
  'Æ': 'Ae', 'æ': 'ae', 'Œ': 'Oe', 'œ': 'oe', 'Þ': 'Th', 'þ': 'th',
};

/** Buchstaben mit Strich oder Haken: NFD zerlegt sie nicht, sie brauchen eine Regel. */
const FOLD_SINGLE = {
  'Ð': 'D', 'ð': 'd', 'Ø': 'O', 'ø': 'o', '×': 'x', '÷': '/',
  'Đ': 'D', 'đ': 'd', 'Ħ': 'H', 'ħ': 'h', 'ı': 'i', 'Ĳ': 'I', 'ĳ': 'i',
  'ĸ': 'k', 'Ŀ': 'L', 'ŀ': 'l', 'Ł': 'L', 'ł': 'l', 'ŉ': 'n', 'Ŋ': 'N',
  'ŋ': 'n', 'Ŧ': 'T', 'ŧ': 't', 'ſ': 's',
};

/**
 * Ein Name in reinem ASCII.
 *
 * Der Ortsspeicher des Edge gibt nur ASCII unveraendert zurueck. "Restaurant
 * Hane" - fuenfzehn ASCII-Bytes, genau an der Grenze - laeuft durch; dasselbe
 * in fuenfzehn Bytes mit zwei Akzent-e kam nicht unveraendert zurueck. Der
 * Wegpunkt stand danach sichtbar auf dem Geraet, war ueber seinen Namen aber
 * nicht mehr zu finden: die Liste blieb auf "teilweise uebertragen", jeder
 * Lauf schrieb ihn erneut.
 *
 * Gefaltet wird vor dem Kuerzen, damit die Ersatzschreibweise noch ins
 * Byte-Budget zaehlt - und weil ein Akzent danach nur noch ein Byte kostet,
 * bleibt mehr vom Namen uebrig. Dieselbe Rechnung macht die App in
 * WaypointWriter.fold(); geht sie hier durch, ist sie dort ein Nulldurchlauf.
 */
export function foldToAscii(text) {
  let out = '';
  for (const ch of String(text ?? '')) {
    const cp = ch.codePointAt(0);
    if (cp >= 0x20 && cp < 0x7f) { out += ch; continue; }
    if (cp === 0xa0) { out += ' '; continue; }
    if (FOLD_PAIRS[ch]) { out += FOLD_PAIRS[ch]; continue; }
    if (FOLD_SINGLE[ch]) { out += FOLD_SINGLE[ch]; continue; }
    if (cp >= 0x2010 && cp <= 0x2015) { out += '-'; continue; }
    if (cp === 0x2018 || cp === 0x2019 || cp === 0x201b) { out += "'"; continue; }
    // Akzente abziehen und nur nehmen, was danach ASCII ist. Der Rest faellt
    // weg: ein Zeichen, das das Geraet nicht fuehren kann, ist im Namen
    // schlimmer als seine Luecke.
    const base = ch.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
    if (/^[\x20-\x7e]+$/.test(base)) { out += base; }
  }
  return out;
}

/** Auf ASCII gefalteter, auf `maxBytes` gekuerzter, von Whitespace befreiter Name. */
export function normaliseName(name, maxBytes) {
  const clean = foldToAscii(name).replace(/\s+/g, ' ').trim();
  const cut = cutToBytes(clean, maxBytes);
  return cut === clean ? clean : cut.trim();
}

/**
 * Der Name, den Google einem gesetzten Pin gibt - die Koordinate selbst, als
 * Grad/Minuten/Sekunden (49°25'25.8"N 7°34'08.0"E) oder dezimal.
 */
const PIN_NAME = [
  /^\d{1,2}°\s*\d{1,2}'\s*\d{1,2}(?:\.\d+)?"\s*[NS]\s+\d{1,3}°\s*\d{1,2}'\s*\d{1,2}(?:\.\d+)?"\s*[EW]$/,
  /^-?\d{1,2}(?:\.\d+)?\s*,\s*-?\d{1,3}(?:\.\d+)?$/
];

/**
 * Lesbarer Name fuer einen Pin, oder null, wenn es keiner ist.
 *
 * Gefaltet und gekuerzt wuerde aus 49°25'25.8"N 7°34'08.0"E ein
 * 4925'25.8"N 734 - ohne Gradzeichen und abgeschnitten, also eine Koordinate,
 * die es nicht gibt. Stattdessen dezimal, mit so vielen Nachkommastellen, wie
 * ins Byte-Budget passen: 4 (~10 m) im Normalfall, weniger bei langen Werten.
 */
export function pinName(name, lat, lon, maxBytes) {
  const text = String(name ?? '').trim();
  if (!PIN_NAME.some((pattern) => pattern.test(text))) return null;
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  for (let digits = 4; digits > 0; digits--) {
    const label = `${lat.toFixed(digits)} ${lon.toFixed(digits)}`;
    if (label.length <= maxBytes) return label;
  }
  return `${lat.toFixed(0)} ${lon.toFixed(0)}`;
}

/** Koordinate auf 5 Nachkommastellen (~1 m). Spart Bytes und haelt den Hash ruhig. */
export function roundCoord(value) {
  return Math.round(Number(value) * 1e5) / 1e5;
}

export function validCoord(lat, lon) {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return false;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return false;
  if (lat === 0 && lon === 0) return false;
  return true;
}

/**
 * Rohe Orte -> Eintraege [name, lat, lon], sortiert, gekuerzt, eindeutig.
 *
 * Die Namen muessen eindeutig sein: auf dem Geraet ist der Name der einzige
 * Schluessel, ueber den ein Wegpunkt wiedergefunden und geloescht werden kann.
 * Und sie muessen stabil sortiert sein, sonst wechselt der Hash bei jedem Lauf
 * und das Geraet laedt jedes Mal alles neu.
 *
 * `nameMaxLength` ist deshalb keine Kosmetik, sondern die Byte-Grenze des
 * Ortsspeichers: der Edge schneidet bei 15 UTF-8-Bytes ab und gibt nur den
 * Rumpf zurueck. Wer hier hoeher geht, macht Namen eindeutig, die auf dem
 * Geraet wieder zusammenfallen - siehe WaypointWriter.deviceNames() in der
 * App, das den Rest auffaengt.
 *
 * Eindeutig gemacht wird nach dem Falten, nicht davor: "Cafe" mit und ohne
 * Akzent sind auf dem Geraet derselbe Name, und der Name ist dort der einzige
 * Schluessel.
 *
 * `previous` sind die Eintraege des zuletzt veroeffentlichten Stands. Ein Ort,
 * der dort schon stand, behaelt seine Kennziffer - neue bekommen die erste
 * freie. Frueher wurde nach der Sortierung durchgezaehlt: kam ein ALDI hinzu,
 * der suedlicher lag als die vorhandenen, rutschten alle dahinter eine Nummer
 * weiter. Das Geraet sah dieselben Namen wie vorher, schrieb nichts, und der
 * neue Ort kam nie an - waehrend der entfernte als "ALDI SUeD 4" stehen blieb.
 * Nummern duerfen dadurch Luecken haben; das ist der Preis fuer Ruhe.
 */
export function normalise(places, { nameMaxLength = 15, previous = [] } = {}) {
  const cleaned = [];
  const seenPlaces = new Set();

  for (const place of places ?? []) {
    const lat = roundCoord(place?.lat);
    const lon = roundCoord(place?.lon);
    const name = normaliseName(
      pinName(place?.name, lat, lon, nameMaxLength) ?? place?.name, nameMaxLength);
    if (name.length === 0 || !validCoord(lat, lon)) continue;

    const key = `${name}|${lat}|${lon}`;
    if (seenPlaces.has(key)) continue;
    seenPlaces.add(key);
    cleaned.push({ name, lat, lon });
  }

  cleaned.sort((a, b) =>
    a.name.localeCompare(b.name, 'en') || a.lat - b.lat || a.lon - b.lon);

  // Die Kennziffer zaehlt gegen dasselbe Byte-Budget: bliebe sie aussen vor,
  // schnitte das Geraet genau sie wieder ab - und die Doppelgaenger fielen
  // doch wieder zusammen.
  const numbered = (name, n) => {
    if (n === 1) return name;
    const suffix = ` ${n}`;
    const room = Math.max(1, nameMaxLength - Buffer.byteLength(suffix, 'utf8'));
    return `${cutToBytes(name, room).trim()}${suffix}`;
  };

  // Alte Namen nach Koordinate, wie sie roundCoord() liefert.
  const before = new Map();
  for (const entry of Array.isArray(previous) ? previous : []) {
    if (!Array.isArray(entry) || typeof entry[0] !== 'string') continue;
    const key = `${roundCoord(entry[1])}|${roundCoord(entry[2])}`;
    if (!before.has(key)) before.set(key, []);
    before.get(key).push(entry[0]);
  }

  /** Der alte Name dieses Orts, wenn er zu seinem heutigen Rumpf passt. */
  const inherited = ({ name, lat, lon }) => {
    for (const old of before.get(`${lat}|${lon}`) ?? []) {
      if (old === name) return old;
      const match = / (\d+)$/.exec(old);
      const n = match ? Number(match[1]) : 0;
      if (n >= 2 && numbered(name, n) === old) return old;
    }
    return null;
  };

  // Zuerst bekommen alle bekannten Orte ihren alten Namen zurueck, erst danach
  // werden die neuen verteilt - sonst schnappte ein neuer Ort, der vorne
  // einsortiert ist, einem bekannten die Nummer weg.
  const used = new Set();
  const names = cleaned.map((place) => {
    const old = inherited(place);
    if (old == null || used.has(old)) return null;
    used.add(old);
    return old;
  });

  return cleaned.map(({ name, lat, lon }, i) => {
    let unique = names[i];
    for (let n = 1; unique == null; n++) {
      const candidate = numbered(name, n);
      if (!used.has(candidate)) unique = candidate;
    }
    used.add(unique);
    return [unique, lat, lon];
  });
}

/** Kurzer Inhalts-Hash. Gleiche Eintraege -> gleicher Hash, sonst nicht. */
export function hashEntries(entries) {
  return createHash('sha1').update(JSON.stringify(entries)).digest('hex').slice(0, 8);
}

/**
 * Listen-Id aus Name und Salt. Das Salt kommt aus einem Repository-Secret,
 * damit die Pages-URLs nicht zu erraten sind - GitHub Pages ist oeffentlich.
 * Verschleierung, keine Sicherheit; steht so auch im README.
 */
export function listId(name, salt) {
  return createHash('sha256').update(`${name} ${salt ?? ''}`).digest('hex').slice(0, 8);
}

export function paginate(entries, pageSize) {
  const size = Math.max(1, pageSize);
  const pages = [];
  for (let i = 0; i < entries.length; i += size) {
    pages.push(entries.slice(i, i + size));
  }
  return pages;
}

/**
 * Darf dieser Stand veroeffentlicht werden?
 *
 * Gesperrt wird nur eine auf null gefallene Liste: das ist das typische Bild
 * eines kaputten Scrapers. Im Zweifel bleibt der alte Stand stehen - das Geraet
 * sieht dann einen unveraenderten Hash und ruehrt seine Favoriten nicht an.
 * Fuer eine bewusst geleerte Liste hebt shrinkAllowed() die Sperre fuer einen
 * einzelnen Lauf auf.
 *
 * Eine stark geschrumpfte Liste geht dagegen durch - kraeftiges Aufraeumen in
 * Google Maps soll ohne Zugestaendnis ankommen. `reason` ist dann trotzdem
 * gesetzt, damit main() es als Warnung ins Log schreibt: ein halb brechender
 * Scraper faellt so wenigstens auf.
 */
export function guard(previousCount, nextCount) {
  if (nextCount === 0 && previousCount > 0) {
    return { ok: false, reason: `leer, vorher ${previousCount}` };
  }
  if (previousCount > 0 && nextCount < Math.floor(previousCount * 0.5)) {
    return { ok: true, reason: `${nextCount} statt ${previousCount} - stark geschrumpft` };
  }
  return { ok: true, reason: '' };
}

/**
 * Hat der Scraper die ganze Liste erwischt?
 *
 * `expected` ist die Anzahl, die Google im Kopf der Liste anzeigt, `found` die
 * Zahl der verschiedenen Orte, die der Scraper ausgelesen hat - vor dem
 * Normalisieren, das legitim noch etwas verwirft.
 *
 * Fehlen Orte, wird nicht veroeffentlicht. Das ist der gefaehrlichere Fall als
 * eine leere Liste: der Lauf sieht gesund aus, das Geraet loescht Favoriten,
 * und weil beim naechsten Lauf andere fehlen, legt es sie wieder an. Anders
 * als guard() hebt ALLOW_SHRINK das nicht auf - eine geschrumpfte Liste kann
 * gewollt sein, eine halb ausgelesene nie, und der manuelle Lauf setzt das
 * Zugestaendnis von sich aus.
 *
 * Ist die Anzahl nicht zu lesen, geht die Liste mit Warnung durch: sonst
 * stuende jede Liste still, sobald Google den Kopf umbaut.
 */
export function completeness(found, expected) {
  if (!Number.isInteger(expected) || expected < 0) {
    return { ok: true, reason: 'Anzahl der Liste nicht lesbar - Vollstaendigkeit ungeprueft' };
  }
  if (found < expected) {
    return { ok: false, reason: `unvollstaendig, ${found} von ${expected} Orten ausgelesen` };
  }
  if (found > expected) {
    return { ok: true, reason: `${found} Orte ausgelesen, die Liste nennt nur ${expected}` };
  }
  return { ok: true, reason: '' };
}

/**
 * Hebt der Lauf die Sperre auf? Kommt als ALLOW_SHRINK aus dem Workflow.
 *
 * Nur ein ausdrueckliches "true" zaehlt. Alles andere - fehlend, leer, "1",
 * "ja" - laesst die Sperre stehen: ein Tippfehler darf nie Favoriten kosten.
 */
export function shrinkAllowed(raw) {
  return String(raw ?? '').trim().toLowerCase() === 'true';
}

/** Findet einen Eintrag im zuvor veroeffentlichten Katalog. */
export function findPrevious(previousIndex, id) {
  const lists = previousIndex?.l;
  if (!Array.isArray(lists)) return null;
  return lists.find((entry) => entry?.i === id) ?? null;
}

/**
 * Hat sich am Katalog inhaltlich etwas geaendert?
 *
 * Verglichen wird nur `l`. `t` ist der Zeitpunkt des Laufs und ist bei jedem
 * Lauf ein anderer - wer index.json deshalb jedes Mal neu schreibt, erzeugt
 * einen Commit pro Lauf, in dem nichts steht als diese Zahl. Zwei davon
 * aendern dieselbe Zeile und kollidieren beim Rebase im Workflow, obwohl
 * inhaltlich nichts passiert ist. Das Geraet liest `t` ohnehin nicht, es
 * haelt sich an `h` je Liste.
 *
 * Der Vergleich ueber JSON.stringify traegt, weil beide Seiten aus derselben
 * Quelle stammen: die Eintraege werden hier in fester Schluesselreihenfolge
 * gebaut und genau so geschrieben, wie sie spaeter wieder eingelesen werden.
 */
export function catalogChanged(previousIndex, catalog) {
  if (previousIndex?.v !== SCHEMA_VERSION) return true;
  return JSON.stringify(previousIndex.l) !== JSON.stringify(catalog);
}

// -- Ausfuehrung -------------------------------------------------------------

async function readJson(file, fallback) {
  try {
    return JSON.parse(await readFile(file, 'utf8'));
  } catch {
    return fallback;
  }
}

/**
 * Die Eintraege des zuletzt veroeffentlichten Stands einer Liste, oder [].
 *
 * Gebraucht nur fuer die Kennziffern in normalise(). Fehlt eine Seite, bleibt
 * es bei dem, was da ist - schlimmstenfalls wird wie frueher neu durchgezaehlt.
 */
async function readPreviousEntries(id, previous) {
  const pages = Number.isInteger(previous?.p) ? previous.p : 0;
  const entries = [];
  for (let i = 0; i < pages; i++) {
    const page = await readJson(path.join(DOCS, 'l', id, `${i}.json`), null);
    if (Array.isArray(page?.e)) entries.push(...page.e);
  }
  return entries;
}

async function writeList(id, pages) {
  const dir = path.join(DOCS, 'l', id);
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });
  for (let i = 0; i < pages.length; i++) {
    await writeFile(path.join(dir, `${i}.json`), JSON.stringify(pages[i]) + '\n');
  }
}

async function main() {
  const config = await readJson(CONFIG, null);
  if (config == null) throw new Error(`lists.config.json fehlt unter ${CONFIG}`);

  const raw = await readJson(CACHE, null);
  if (raw == null) throw new Error(`Keine Scraper-Ergebnisse unter ${CACHE} - erst scrape.mjs laufen lassen`);

  const previousIndex = await readJson(path.join(DOCS, 'index.json'), null);

  // Das Salt geht in jede Listen-Id ein. Fehlt es oder wechselt es, heissen
  // saemtliche Listen anders: der vorher veroeffentlichte Katalog wird dann
  // nicht mehr wiedergefunden, seine Schutzwirkung entfaellt, und das Geraet
  // sieht statt seiner Listen einen leeren Katalog. Lieber laut abbrechen.
  const salt = process.env.LIST_SALT ?? '';
  if (salt.trim().length === 0) {
    throw new Error('LIST_SALT fehlt - ohne es aendern sich alle Listen-Ids. '
      + 'Als Repository-Secret setzen (Actions) bzw. lokal mitgeben.');
  }
  const pageSize = config.pageSize ?? 25;
  const nameMaxLength = config.nameMaxLength ?? 15;
  const allowShrink = shrinkAllowed(process.env.ALLOW_SHRINK);
  if (allowShrink) console.log('Sperre fuer diesen Lauf aufgehoben (ALLOW_SHRINK)');

  const catalog = [];
  const failures = [];

  for (const list of config.lists ?? []) {
    const id = listId(list.name, salt);
    const previous = findPrevious(previousIndex, id);
    const result = raw.lists?.[list.name];

    if (!result?.ok) {
      failures.push(`${list.name}: ${result?.error ?? 'nicht abgerufen'}`);
      if (previous) catalog.push(previous);
      continue;
    }

    const coverage = completeness(result.places?.length ?? 0, result.expected);
    if (!coverage.ok) {
      failures.push(`${list.name}: ${coverage.reason}`);
      if (previous) catalog.push(previous);
      continue;
    }
    if (coverage.reason) console.log(`::warning::${list.name}: ${coverage.reason}`);

    const entries = normalise(result.places, {
      nameMaxLength,
      previous: await readPreviousEntries(id, previous)
    });
    const verdict = guard(previous?.c ?? 0, entries.length);
    if (!verdict.ok && !allowShrink) {
      failures.push(`${list.name}: ${verdict.reason}`);
      catalog.push(previous);
      continue;
    }
    if (!verdict.ok) {
      console.log(`${list.name}: trotz Sperre veroeffentlicht - ${verdict.reason}`);
    } else if (verdict.reason) {
      // ::warning:: macht daraus eine Annotation am Lauf, ohne ihn rot zu faerben.
      console.log(`::warning::${list.name}: veroeffentlicht - ${verdict.reason}`);
    }

    const hash = hashEntries(entries);
    const pages = paginate(entries, pageSize);

    if (previous?.h === hash) {
      // Gleicher Inhalt: Dateien bleiben liegen, aber der Anzeigename im
      // Katalog folgt der Konfiguration.
      catalog.push({ i: id, n: list.name, c: entries.length, h: hash, p: pages.length });
      console.log(`${list.name}: unveraendert (${entries.length})`);
      continue;
    }

    await writeList(id, pages.map((page, i) => ({
      i: id, h: hash, p: i, n: pages.length, e: page
    })));
    catalog.push({ i: id, n: list.name, c: entries.length, h: hash, p: pages.length });
    console.log(`${list.name}: ${entries.length} Orte, ${pages.length} Seiten, ${hash}`);
  }

  await mkdir(DOCS, { recursive: true });
  await writeFile(path.join(DOCS, '.nojekyll'), '');

  if (catalogChanged(previousIndex, catalog)) {
    await writeFile(
      path.join(DOCS, 'index.json'),
      JSON.stringify({
        v: SCHEMA_VERSION,
        t: Math.floor(Date.now() / 1000),
        l: catalog
      }) + '\n'
    );
  } else {
    console.log('Katalog unveraendert - index.json bleibt liegen');
  }

  if (failures.length > 0) {
    console.error('\nNicht veroeffentlicht:');
    for (const failure of failures) console.error(`  ${failure}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
