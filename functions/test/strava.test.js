'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const s = require('../lib/strava');

const now = new Date('2024-02-01T12:00:00.000Z');

test('challenge: echoes hub.challenge only for the right mode and verify token', () => {
  const ok = s.challengeResponse({ 'hub.mode': 'subscribe', 'hub.verify_token': 'secret', 'hub.challenge': 'abc123' }, 'secret');
  assert.deepEqual(ok, { status: 200, body: { 'hub.challenge': 'abc123' } });
  for (const query of [
    { 'hub.mode': 'subscribe', 'hub.verify_token': 'wrong', 'hub.challenge': 'x' },
    { 'hub.mode': 'unsubscribe', 'hub.verify_token': 'secret', 'hub.challenge': 'x' },
    { 'hub.mode': 'subscribe', 'hub.verify_token': 'secret' },
    {},
  ]) assert.equal(s.challengeResponse(query, 'secret').status, 403);
  // An unset server secret must never match an unset query value.
  assert.equal(s.challengeResponse({ 'hub.mode': 'subscribe', 'hub.challenge': 'x' }, undefined).status, 403);
});

const base = { object_type: 'activity', object_id: 1360128428, aspect_type: 'create', owner_id: 134815, subscription_id: 120475, event_time: 1516126040, updates: {} };

test('parseEvent: accepts a real-shaped event and derives a deterministic dedupe id', () => {
  const parsed = s.parseEvent(base, 120475);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.id, 'activity-1360128428-create-1516126040');
  assert.deepEqual(s.parseEvent({ ...base }, '120475').event, parsed.event);   // string/number subscription ids both work
});

test('parseEvent: rejects forged or malformed events', () => {
  const bad = (patch, reason) => assert.deepEqual(s.parseEvent({ ...base, ...patch }, 120475), { ok: false, reason });
  bad({ subscription_id: 999 }, 'subscription_id');
  bad({ object_type: 'club' }, 'object_type');
  bad({ aspect_type: 'drop' }, 'aspect_type');
  bad({ object_id: '1' }, 'object_id');
  bad({ object_id: -4 }, 'object_id');
  bad({ owner_id: null }, 'owner_id');
  bad({ event_time: 'now' }, 'event_time');
  assert.equal(s.parseEvent(null, 1).ok, false);
  assert.equal(s.parseEvent('x', 1).ok, false);
});

test('actionFor: sync, delete and deauthorize are told apart', () => {
  const act = (patch) => s.actionFor(s.parseEvent({ ...base, ...patch }, 120475).event);
  assert.equal(act({}), 'sync-activity');
  assert.equal(act({ aspect_type: 'update', updates: { title: 'New' } }), 'sync-activity');
  assert.equal(act({ aspect_type: 'delete' }), 'delete-activity');
  assert.equal(act({ object_type: 'athlete', aspect_type: 'update', updates: { authorized: 'false' } }), 'deauthorize');
  assert.equal(act({ object_type: 'athlete', aspect_type: 'update', updates: { authorized: 'true' } }), 'ignore');
  assert.equal(act({ object_type: 'athlete', aspect_type: 'create' }), 'ignore');
});

const raw = {
  id: 12345678987654321, // not a safe integer on purpose in the next test; real ids fit
};
const run = { id: 9876543210, name: 'Morning Run', sport_type: 'Run', type: 'Run', start_date: '2024-01-15T07:30:00Z',
  moving_time: 1805.4, elapsed_time: 1900, distance: 5234.56, total_elevation_gain: 41.04, average_heartrate: 151.6, athlete: { id: 134815 } };

test('mapActivity: produces the document the app decodes (golden contract shared with the Swift tests)', () => {
  const doc = s.mapActivity(run, { studentID: 'student-1', ownerId: 134815, now: new Date('2024-01-15T09:00:00Z') });
  const wire = JSON.parse(JSON.stringify(doc, (key, value) => value));   // Dates → ISO strings first…
  // …then to the wire form the app sees after FirestoreValues.decode: Date → { "$date": epochSeconds }.
  const toWire = (v) => (v instanceof Date ? { $date: v.getTime() / 1000 }
    : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, toWire(x)])) : v);
  const golden = JSON.parse(fs.readFileSync(path.join(__dirname, '../../contract/external-activity.golden.json'), 'utf8'));
  assert.deepEqual(toWire(doc), golden);
  assert.ok(wire);
});

test('mapActivity: rounds, bounds and omits what is missing', () => {
  const minimal = s.mapActivity({ id: 1, name: '  ', type: 'Yoga', start_date: '2024-01-15T07:30:00Z', moving_time: 60, elapsed_time: 60 },
    { studentID: 'st', ownerId: 5, now });
  assert.equal(minimal.name, 'Yoga');                    // empty name falls back to the sport
  assert.equal(minimal.sportType, 'Yoga');
  assert.equal('distanceMeters' in minimal, false);
  assert.equal('averageHeartRate' in minimal, false);

  const wild = s.mapActivity({ ...run, name: 'x'.repeat(500) + '\u0007', moving_time: -5, distance: NaN }, { studentID: 'st', ownerId: 134815, now });
  assert.equal(wild.name.length, 120);
  assert.equal(wild.movingSeconds, 0);
  assert.equal('distanceMeters' in wild, false);
});

test('mapActivity: refuses private, foreign and malformed activities', () => {
  const ctx = { studentID: 'st', ownerId: 134815, now };
  assert.equal(s.mapActivity({ ...run, private: true }, ctx), null);
  assert.equal(s.mapActivity({ ...run, visibility: 'only_me' }, ctx), null);
  assert.equal(s.mapActivity({ ...run, athlete: { id: 42 } }, ctx), null);       // belongs to someone else
  assert.equal(s.mapActivity({ ...run, start_date: 'yesterday' }, ctx), null);
  assert.equal(s.mapActivity({ ...run, id: 'abc' }, ctx), null);
  assert.equal(s.mapActivity(null, ctx), null);
  assert.equal(raw.id > 0, true);
});

test('tombstone: bumps the version and stamps deletedAt, keeping the rest', () => {
  const doc = s.mapActivity(run, { studentID: 'st', ownerId: 134815, now });
  const gone = s.tombstone(doc, new Date('2024-03-01T00:00:00Z'));
  assert.equal(gone.meta.version, 2);
  assert.equal(gone.meta.deletedAt.toISOString(), '2024-03-01T00:00:00.000Z');
  assert.equal(gone.name, doc.name);
  assert.equal(doc.meta.deletedAt, undefined);           // input untouched
});

test('authorize URL: https strava.com, only activity:read, carries our state', () => {
  const url = new URL(s.buildAuthorizeUrl({ clientId: 12345, redirectUri: 'https://fn.example/stravaCallback', state: 'st4te' }));
  assert.equal(url.origin + url.pathname, 'https://www.strava.com/oauth/authorize');
  assert.equal(url.searchParams.get('scope'), 'activity:read');
  assert.equal(url.searchParams.get('state'), 'st4te');
  assert.equal(url.searchParams.get('response_type'), 'code');
  assert.equal(url.searchParams.get('redirect_uri'), 'https://fn.example/stravaCallback');
});

test('state: bound to the uid, expires, and unknown/empty states are rejected', () => {
  const record = s.newStateRecord('uid-1', 1_000_000);
  assert.deepEqual(s.validateState(record, 1_000_001), { ok: true, uid: 'uid-1' });
  assert.deepEqual(s.validateState(record, 1_000_000 + s.STATE_TTL_MS), { ok: false, reason: 'expired' });
  assert.deepEqual(s.validateState(undefined, 1), { ok: false, reason: 'unknown-state' });
  assert.deepEqual(s.validateState({ uid: '', expiresAt: 9e12 }, 1), { ok: false, reason: 'unknown-state' });
});

test('callback: denial, missing params and a de-selected scope are all refused', () => {
  assert.deepEqual(s.parseCallback({ error: 'access_denied' }), { ok: false, reason: 'denied' });
  assert.deepEqual(s.parseCallback({ code: 'c' }), { ok: false, reason: 'missing-params' });
  assert.deepEqual(s.parseCallback({ code: 'c', state: 's', scope: 'read' }), { ok: false, reason: 'insufficient-scope' });
  assert.deepEqual(s.parseCallback({ code: 'c', state: 's', scope: 'read,activity:read' }), { ok: true, code: 'c', state: 's' });
  assert.equal(s.parseCallback({ code: 'c', state: 's' }).ok, true);     // no scope param → fall back to what the token reports
});

test('tokens: parsing and refresh timing', () => {
  assert.deepEqual(s.parseTokenResponse({ access_token: 'a', refresh_token: 'r', expires_at: 2000, athlete: { id: 7 } }),
    { accessToken: 'a', refreshToken: 'r', expiresAt: 2000, athleteId: 7 });
  assert.equal(s.parseTokenResponse({ access_token: 'a' }), null);
  assert.equal(s.parseTokenResponse(null), null);
  assert.equal(s.tokenNeedsRefresh({ expiresAt: 2000 }, 1000), false);
  assert.equal(s.tokenNeedsRefresh({ expiresAt: 1200 }, 1000), true);    // inside the 5-minute skew
  assert.equal(s.tokenNeedsRefresh(null, 1000), true);
});
