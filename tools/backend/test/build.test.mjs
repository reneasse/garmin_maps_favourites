import test from 'node:test';
import assert from 'node:assert/strict';

import {
  normaliseName, normalise, roundCoord, validCoord,
  hashEntries, listId, paginate, guard, findPrevious, catalogChanged,
  SCHEMA_VERSION
} from '../build.mjs';
import {
  parseUrlOverrides, usableUrl, splitJsonObjects, unwrapPayload,
  placesFromPayload, dedupe
} from '../scrape.mjs';

/**
 * Eine Antwort in der Form, die Google liefert: ein Stueck {"c":..,"d":".."},
 * dessen d-Feld die Nutzlast als JSON-Text traegt, mit XSSI-Vorspann.
 *
 * Nachgebaut statt mitgeschnitten - eine echte Antwort enthaelt Rezensionen
 * samt Klarnamen Dritter, und die haben in einem Repository nichts zu suchen.
 * Die Form stammt aus einer echten Antwort, die Inhalte sind erfunden.
 */
function antwort(...orte) {
  const payload = `[["*",[[null,null,${orte.map((o) =>
    `null,[null,null,${o.lat},${o.lon}],${JSON.stringify(o.id)},${JSON.stringify(o.name)},null,["Supermarkt"]`
  ).join(',')}]]]]`;
  return JSON.stringify({ c: 0, d: `)]}'\n${payload}`, e: null });
}

test('Namen werden gekuerzt und von Whitespace befreit', () => {
  assert.equal(normaliseName('  Cafe   Central  ', 20), 'Cafe Central');
  assert.equal(normaliseName('Ein sehr langer Ortsname hier', 20), 'Ein sehr langer Orts');
  assert.equal(normaliseName(null, 20), '');
});

test('Koordinaten werden gerundet und geprueft', () => {
  assert.equal(roundCoord(48.137212345), 48.13721);
  assert.equal(validCoord(48.1, 11.5), true);
  assert.equal(validCoord(0, 0), false);
  assert.equal(validCoord(91, 11), false);
  assert.equal(validCoord(NaN, 11), false);
});

test('normalise sortiert, filtert und macht Namen eindeutig', () => {
  const entries = normalise([
    { name: 'Zebra', lat: 48.1, lon: 11.1 },
    { name: 'Alpha', lat: 48.2, lon: 11.2 },
    { name: 'Alpha', lat: 48.3, lon: 11.3 },
    { name: 'Nullinsel', lat: 0, lon: 0 },
    { name: '', lat: 48.4, lon: 11.4 }
  ], { nameMaxLength: 20 });

  assert.deepEqual(entries.map((e) => e[0]), ['Alpha', 'Alpha 2', 'Zebra']);
});

test('normalise wirft echte Dubletten weg', () => {
  const entries = normalise([
    { name: 'Cafe', lat: 48.1, lon: 11.1 },
    { name: 'Cafe', lat: 48.1, lon: 11.1 }
  ]);
  assert.equal(entries.length, 1);
});

test('eindeutige Namen bleiben innerhalb der Laengengrenze', () => {
  const entries = normalise([
    { name: 'Abcdefghij', lat: 48.1, lon: 11.1 },
    { name: 'Abcdefghij', lat: 48.2, lon: 11.2 }
  ], { nameMaxLength: 10 });

  assert.deepEqual(entries.map((e) => e[0]), ['Abcdefghij', 'Abcdefgh 2']);
  for (const entry of entries) assert.ok(entry[0].length <= 10);
});

test('der Hash haengt nur am Inhalt, nicht an der Eingabereihenfolge', () => {
  const a = normalise([
    { name: 'B', lat: 48.2, lon: 11.2 },
    { name: 'A', lat: 48.1, lon: 11.1 }
  ]);
  const b = normalise([
    { name: 'A', lat: 48.1, lon: 11.1 },
    { name: 'B', lat: 48.2, lon: 11.2 }
  ]);
  assert.equal(hashEntries(a), hashEntries(b));

  const c = normalise([{ name: 'A', lat: 48.1, lon: 11.1 }]);
  assert.notEqual(hashEntries(a), hashEntries(c));
});

test('Listen-Ids sind stabil und salzabhaengig', () => {
  assert.equal(listId('Cafes', 'salz'), listId('Cafes', 'salz'));
  assert.notEqual(listId('Cafes', 'salz'), listId('Cafes', 'pfeffer'));
  assert.notEqual(listId('Cafes', 'salz'), listId('Baeder', 'salz'));
  assert.match(listId('Cafes', 'salz'), /^[0-9a-f]{8}$/);
});

test('paginate schneidet in Seiten fester Groesse', () => {
  const entries = Array.from({ length: 7 }, (_, i) => [`N${i}`, 48, 11]);
  const pages = paginate(entries, 3);
  assert.equal(pages.length, 3);
  assert.equal(pages[0].length, 3);
  assert.equal(pages[2].length, 1);
  assert.equal(paginate([], 25).length, 0);
});

test('die Sperre haelt leere und geschrumpfte Listen zurueck', () => {
  assert.equal(guard(10, 0).ok, false);
  assert.equal(guard(10, 4).ok, false);
  assert.equal(guard(10, 5).ok, true);
  assert.equal(guard(10, 12).ok, true);
  // Erster Lauf: es gibt nichts zu verlieren.
  assert.equal(guard(0, 0).ok, true);
  assert.equal(guard(0, 30).ok, true);
});

test('findPrevious sucht im alten Katalog', () => {
  const index = { v: 1, l: [{ i: 'aa', h: 'h1', c: 3 }] };
  assert.equal(findPrevious(index, 'aa').h, 'h1');
  assert.equal(findPrevious(index, 'zz'), null);
  assert.equal(findPrevious(null, 'aa'), null);
});

test('ein gleicher Katalog gilt nicht als Aenderung', () => {
  const list = { i: 'aa', n: 'Cafes', c: 3, h: 'h1', p: 1 };
  const previous = { v: SCHEMA_VERSION, t: 1757260800, l: [list] };

  // Nur der Zeitstempel unterscheidet sich - das ist keine Aenderung.
  assert.equal(catalogChanged(previous, [{ ...list }]), false);
  assert.equal(catalogChanged({ ...previous, t: 1 }, [{ ...list }]), false);

  assert.equal(catalogChanged(previous, [{ ...list, h: 'h2' }]), true);
  assert.equal(catalogChanged(previous, [{ ...list, n: 'Baeder' }]), true);
  assert.equal(catalogChanged(previous, []), true);
});

test('ohne brauchbaren Vorgaenger wird immer geschrieben', () => {
  assert.equal(catalogChanged(null, []), true);
  assert.equal(catalogChanged({}, []), true);
  // Anderes Schema: der alte Katalog sagt nichts ueber den neuen aus.
  assert.equal(catalogChanged({ v: SCHEMA_VERSION + 1, l: [] }, []), true);
});

test('Share-Links koennen aus dem Secret kommen', () => {
  assert.deepEqual(
    parseUrlOverrides('{"Cafes":"https://maps.app.goo.gl/abc"}'),
    { Cafes: 'https://maps.app.goo.gl/abc' });

  // Unbrauchbares darf nie eine leere Liste vortaeuschen, sondern faellt weg.
  assert.deepEqual(parseUrlOverrides(undefined), {});
  assert.deepEqual(parseUrlOverrides(''), {});
  assert.deepEqual(parseUrlOverrides('kein json'), {});
  assert.deepEqual(parseUrlOverrides('["a"]'), {});
  assert.deepEqual(parseUrlOverrides('{"Cafes":123}'), {});
});

test('Platzhalter zaehlen nicht als Link', () => {
  assert.equal(usableUrl('https://maps.app.goo.gl/abc'), true);
  assert.equal(usableUrl('https://maps.app.goo.gl/REPLACE_ME'), false);
  assert.equal(usableUrl(undefined), false);
  assert.equal(usableUrl(''), false);
});

test('aneinandergehaengte JSON-Stuecke werden einzeln getrennt', () => {
  assert.deepEqual(splitJsonObjects('{"a":1}{"b":2}'), ['{"a":1}', '{"b":2}']);

  // Klammern im Text duerfen nicht als Ende zaehlen, Escapes ebenso wenig.
  assert.deepEqual(splitJsonObjects('{"a":"}{"}'), ['{"a":"}{"}']);
  assert.deepEqual(splitJsonObjects('{"a":"\\""}'), ['{"a":"\\""}']);

  assert.deepEqual(splitJsonObjects(''), []);
  assert.deepEqual(splitJsonObjects(null), []);
  // Angeschnittenes bleibt liegen, statt halb verwertet zu werden.
  assert.deepEqual(splitJsonObjects('{"a":1'), []);
});

test('die Nutzlast kommt aus den d-Feldern, ohne XSSI-Vorspann', () => {
  const zwei = JSON.stringify({ c: 0, d: ')]}\'\n[1,' }) + JSON.stringify({ c: 1, d: '2]' });
  assert.equal(unwrapPayload(zwei), '[1,2]');

  // Nichts Verwertbares darf still zu einer leeren Nutzlast werden.
  assert.equal(unwrapPayload(''), '');
  assert.equal(unwrapPayload('{"c":0}'), '');
});

test('Orte kommen aus der Antwort, samt Namen mit Sonderzeichen', () => {
  const places = placesFromPayload(antwort(
    { id: '0x47bee1eb3abfab1d:0xbaafb8a90b504ece', name: 'REWE Frédéric Cahon', lat: 50.7324447, lon: 7.075263 },
    { id: '0xaaaa:0xbbbb', name: 'Cafe "Zum Eck"', lat: 48.13721, lon: 11.57559 }
  ));

  assert.equal(places.length, 2);
  assert.deepEqual(places[0], {
    id: '0x47bee1eb3abfab1d:0xbaafb8a90b504ece',
    name: 'REWE Frédéric Cahon',
    lat: 50.7324447,
    lon: 7.075263
  });
  assert.equal(places[1].name, 'Cafe "Zum Eck"');
});

test('nur Orte zaehlen, nicht jedes Koordinatenpaar', () => {
  // Fotos und Rezensionen tragen dieselbe [null,null,lat,lon]-Form, aber keine
  // Ortskennung dahinter. Ohne diese Bedingung wanderten sie als Favoriten mit.
  const foto = '{"c":0,"d":")]}\'\\n[[[2],[[null,null,50.7321838,7.0752618]]]]"}';
  assert.deepEqual(placesFromPayload(foto), []);

  assert.deepEqual(placesFromPayload(''), []);
  assert.deepEqual(placesFromPayload('kein json'), []);
});

test('dedupe haelt jeden Ort nur einmal und legt die Kennung ab', () => {
  const roh = [
    { id: '0xa:0xb', name: 'Cafe', lat: 48.1, lon: 11.1 },
    { id: '0xa:0xb', name: 'Cafe', lat: 48.1, lon: 11.1 },
    { id: '0xc:0xd', name: 'Bar', lat: 48.2, lon: 11.2 }
  ];
  const out = dedupe(roh);
  assert.equal(out.length, 2);
  // build.mjs erwartet genau diese drei Felder.
  assert.deepEqual(Object.keys(out[0]).sort(), ['lat', 'lon', 'name']);
  assert.deepEqual(dedupe(null), []);
});
