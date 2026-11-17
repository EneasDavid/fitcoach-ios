'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const places = require('../lib/places');
const { consume } = require('../lib/ratelimit');
const { bearerToken, authenticate } = require('../lib/http');

test('validateSearch: rejects bad coordinates, clamps the radius, defaults it', () => {
  assert.equal(places.validateSearch(null).ok, false);
  assert.deepEqual(places.validateSearch({ latitude: 91, longitude: 0 }), { ok: false, reason: 'latitude' });
  assert.deepEqual(places.validateSearch({ latitude: 0, longitude: '1' }), { ok: false, reason: 'longitude' });
  assert.equal(places.validateSearch({ latitude: -9.6, longitude: -35.7, radiusMeters: 99999 }).radiusMeters, 5000);
  assert.equal(places.validateSearch({ latitude: -9.6, longitude: -35.7, radiusMeters: 1 }).radiusMeters, 100);
  assert.equal(places.validateSearch({ latitude: -9.6, longitude: -35.7 }).radiusMeters, 1000);
});

test('buildNearbyRequest: gym type, circle restriction, minimal field mask, and no API key', () => {
  const request = places.buildNearbyRequest({ latitude: -9.66, longitude: -35.73, radiusMeters: 800 }, 50);
  assert.equal(request.url, 'https://places.googleapis.com/v1/places:searchNearby');
  assert.equal(request.fieldMask, 'places.id,places.displayName,places.location');
  assert.deepEqual(request.body.includedTypes, ['gym']);
  assert.equal(request.body.maxResultCount, 20);                       // capped
  assert.deepEqual(request.body.locationRestriction.circle, { center: { latitude: -9.66, longitude: -35.73 }, radius: 800 });
  assert.equal(JSON.stringify(request).toLowerCase().includes('key'), false);
});

test('mapPlaces: keeps valid places, drops malformed ones', () => {
  const mapped = places.mapPlaces({ places: [
    { id: 'ChIJ1', displayName: { text: 'Smart Fit Centro', languageCode: 'pt' }, location: { latitude: -9.66, longitude: -35.73 } },
    { id: '', displayName: { text: 'No id' }, location: { latitude: 1, longitude: 1 } },
    { id: 'ChIJ2', displayName: {}, location: { latitude: 1, longitude: 1 } },
    { id: 'ChIJ3', displayName: { text: 'No location' } },
    null,
  ] });
  assert.deepEqual(mapped, [{ id: 'ChIJ1', name: 'Smart Fit Centro', latitude: -9.66, longitude: -35.73 }]);
  assert.deepEqual(places.mapPlaces({}), []);
  assert.deepEqual(places.mapPlaces(null), []);
});

test('rate limit: counts inside the window, blocks at the limit, resets after it', () => {
  const policy = { limit: 3, windowMs: 60_000 };
  let counter;
  for (let i = 0; i < 3; i += 1) {
    const result = consume(counter, 1_000 + i, policy);
    assert.equal(result.allowed, true);
    counter = result.next;
  }
  const blocked = consume(counter, 10_000, policy);
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.retryAfterSeconds, 51);
  assert.equal(consume(counter, 61_000, policy).allowed, true);       // new window
});

test('bearerToken parsing', () => {
  assert.equal(bearerToken('Bearer abc.def'), 'abc.def');
  assert.equal(bearerToken('bearer abc'), 'abc');
  assert.equal(bearerToken('Basic abc'), null);
  assert.equal(bearerToken(undefined), null);
  assert.equal(bearerToken('Bearer'), null);
});

test('authenticate: needs App Check AND a valid ID token; every failure is a 401', async () => {
  const good = { verifyIdToken: async () => ({ uid: 'u1' }), verifyAppCheck: async () => ({}) };
  const headers = { authorization: 'Bearer t', 'x-firebase-appcheck': 'ac' };
  assert.deepEqual(await authenticate(headers, good), { ok: true, uid: 'u1' });
  assert.equal((await authenticate({ 'x-firebase-appcheck': 'ac' }, good)).error, 'missing-token');
  assert.equal((await authenticate({ authorization: 'Bearer t' }, good)).error, 'missing-app-check');
  assert.equal((await authenticate(headers, { ...good, verifyAppCheck: async () => { throw new Error('x'); } })).error, 'bad-app-check');
  assert.equal((await authenticate(headers, { ...good, verifyIdToken: async () => { throw new Error('x'); } })).error, 'bad-token');
  assert.equal((await authenticate(headers, { ...good, verifyIdToken: async () => ({}) })).error, 'bad-token');
});
