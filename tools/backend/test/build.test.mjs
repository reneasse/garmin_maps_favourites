import test from 'node:test';
import assert from 'node:assert/strict';

import {
  normaliseName, normalise, roundCoord, validCoord,
  hashEntries, listId, paginate, guard, findPrevious
} from '../build.mjs';
import { coordsFromHref, toPlaces, parseUrlOverrides, usableUrl } from '../scrape.mjs';

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

test('Koordinaten kommen aus dem Ortslink, nicht aus dem Kartenmittelpunkt', () => {
  const href = 'https://www.google.com/maps/place/Cafe/@48.0,11.0,17z/data=!4m7!3m6!8m2!3d48.13721!4d11.57559';
  assert.deepEqual(coordsFromHref(href), { lat: 48.13721, lon: 11.57559 });

  // Ohne !3d/!4d bleibt nur der Mittelpunkt.
  assert.deepEqual(
    coordsFromHref('https://www.google.com/maps/place/X/@48.5,11.5,17z'),
    { lat: 48.5, lon: 11.5 });

  assert.equal(coordsFromHref('https://www.google.com/maps/place/X'), null);
  assert.equal(coordsFromHref(null), null);
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

test('toPlaces wirft Treffer ohne Namen oder Koordinaten weg', () => {
  const places = toPlaces([
    { name: '  Cafe Central ', href: 'x!3d48.1!4d11.1' },
    { name: '', href: 'x!3d48.2!4d11.2' },
    { name: 'Ohne Koordinaten', href: 'https://www.google.com/maps/place/X' }
  ]);
  assert.deepEqual(places, [{ name: 'Cafe Central', lat: 48.1, lon: 11.1 }]);
});
