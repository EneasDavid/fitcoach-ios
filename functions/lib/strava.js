'use strict';
// Strava integration — pure logic (no Firebase, no network), so every rule below is unit-tested.
//
// Flow
//   connect   app ─► stravaConnectStart (mints `state` bound to the signed-in uid) ─► Strava authorize page
//             Strava ─► stravaCallback?code&state ─► exchange code (client secret stays here) ─► tokens stored server-side
//   webhook   Strava ─► POST stravaWebhook (events are NOT signed) ─► validate shape + subscription id ─► enqueue (fast, 2 s limit)
//             processStravaEvent ─► refetch the activity with the athlete's own token ─► write students/{uid}/externalActivities
//   Because an event is only a *hint* and the activity is always refetched with that athlete's token, a forged event
//   can at most cause one extra API call — it can never inject data.

const AUTHORIZE_URL = 'https://www.strava.com/oauth/authorize';
const SCOPE = 'activity:read';          // public/followers activities only; private ones are never requested
const STATE_TTL_MS = 10 * 60 * 1000;
const MAX_NAME = 120;

/** GET callback validation handshake: echo hub.challenge iff the verify token matches. */
function challengeResponse(query, verifyToken) {
  if (!verifyToken || query['hub.mode'] !== 'subscribe' || query['hub.verify_token'] !== verifyToken || !query['hub.challenge']) {
    return { status: 403, body: { error: 'forbidden' } };
  }
  return { status: 200, body: { 'hub.challenge': String(query['hub.challenge']) } };
}

const OBJECT_TYPES = new Set(['activity', 'athlete']);
const ASPECTS = new Set(['create', 'update', 'delete']);

/**
 * Validates a webhook POST body. `expectedSubscriptionId` (our one subscription) rejects events that merely
 * look right. Returns { ok: true, event, id } where `id` is a deterministic dedupe key, or { ok: false, reason }.
 */
function parseEvent(body, expectedSubscriptionId) {
  if (!body || typeof body !== 'object') return { ok: false, reason: 'not-an-object' };
  const { object_type: objectType, aspect_type: aspectType, object_id: objectId, owner_id: ownerId, event_time: eventTime } = body;
  if (!OBJECT_TYPES.has(objectType)) return { ok: false, reason: 'object_type' };
  if (!ASPECTS.has(aspectType)) return { ok: false, reason: 'aspect_type' };
  if (!Number.isSafeInteger(objectId) || objectId <= 0) return { ok: false, reason: 'object_id' };
  if (!Number.isSafeInteger(ownerId) || ownerId <= 0) return { ok: false, reason: 'owner_id' };
  if (!Number.isSafeInteger(eventTime) || eventTime <= 0) return { ok: false, reason: 'event_time' };
  if (expectedSubscriptionId != null && String(body.subscription_id) !== String(expectedSubscriptionId)) {
    return { ok: false, reason: 'subscription_id' };
  }
  const updates = body.updates && typeof body.updates === 'object' ? body.updates : {};
  const event = { objectType, aspectType, objectId, ownerId, eventTime, updates };
  return { ok: true, event, id: `${objectType}-${objectId}-${aspectType}-${eventTime}` };
}

/** What to do with a validated event. */
function actionFor(event) {
  if (event.objectType === 'athlete') {
    return event.aspectType === 'update' && String(event.updates.authorized) === 'false' ? 'deauthorize' : 'ignore';
  }
  if (event.aspectType === 'delete') return 'delete-activity';
  return 'sync-activity';           // create / update
}

/** Strava activity JSON → the ExternalActivity document the app decodes. Returns null for anything we must not store. */
function mapActivity(raw, { studentID, ownerId, deviceID = 'cloud-function', now }) {
  if (!raw || typeof raw !== 'object' || !Number.isSafeInteger(raw.id)) return null;
  // The activity must belong to the athlete the event/token is for.
  if (raw.athlete && raw.athlete.id !== ownerId) return null;
  // Data minimisation: never keep activities the athlete marked private.
  if (raw.private === true || raw.visibility === 'only_me') return null;
  const startedAt = new Date(raw.start_date);
  if (Number.isNaN(startedAt.getTime())) return null;

  const int = (v) => (Number.isFinite(v) && v >= 0 ? Math.round(v) : 0);
  const optional = (v, round) => (Number.isFinite(v) && v >= 0 ? (round ? Math.round(v) : Math.round(v * 10) / 10) : undefined);
  const sport = String(raw.sport_type || raw.type || 'Workout').slice(0, 40);
  const name = String(raw.name || sport).replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, MAX_NAME) || sport;

  const doc = {
    id: `strava-${raw.id}`,
    studentID,
    source: 'strava',
    externalID: String(raw.id),
    sportType: sport,
    name,
    startedAt,
    movingSeconds: int(raw.moving_time),
    elapsedSeconds: int(raw.elapsed_time),
    meta: { version: 1, updatedAt: now, lastWriterDeviceID: deviceID },
  };
  const distance = optional(raw.distance);
  const elevation = optional(raw.total_elevation_gain);
  const heartRate = optional(raw.average_heartrate, true);
  if (distance !== undefined) doc.distanceMeters = distance;
  if (elevation !== undefined) doc.elevationGainMeters = elevation;
  if (heartRate !== undefined) doc.averageHeartRate = heartRate;
  return doc;
}

/** Marks an existing document deleted (rules forbid hard deletes: every device must see the removal). */
function tombstone(existing, now, deviceID = 'cloud-function') {
  return { ...existing, meta: { ...existing.meta, version: (existing.meta?.version || 0) + 1, updatedAt: now, lastWriterDeviceID: deviceID, deletedAt: now } };
}

// ---- OAuth ----

function buildAuthorizeUrl({ clientId, redirectUri, state }) {
  const url = new URL(AUTHORIZE_URL);
  url.searchParams.set('client_id', String(clientId));
  url.searchParams.set('redirect_uri', redirectUri);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('approval_prompt', 'auto');
  url.searchParams.set('scope', SCOPE);
  url.searchParams.set('state', state);
  return url.toString();
}

function newStateRecord(uid, nowMs) {
  return { uid, expiresAt: nowMs + STATE_TTL_MS };
}

/** `record` is the stored state document (or undefined). One use only: the caller deletes it right after. */
function validateState(record, nowMs) {
  if (!record || typeof record.uid !== 'string' || !record.uid) return { ok: false, reason: 'unknown-state' };
  if (!(record.expiresAt > nowMs)) return { ok: false, reason: 'expired' };
  return { ok: true, uid: record.uid };
}

/** Strava lets the user untick scopes on the consent screen, so check what was really granted. */
function parseCallback(query) {
  if (query.error) return { ok: false, reason: 'denied' };
  if (!query.code || !query.state) return { ok: false, reason: 'missing-params' };
  const granted = String(query.scope || '').split(',').map((s) => s.trim());
  if (query.scope !== undefined && !granted.includes(SCOPE)) return { ok: false, reason: 'insufficient-scope' };
  return { ok: true, code: String(query.code), state: String(query.state) };
}

/** Token endpoint response → what we persist. `expires_at` is epoch seconds. */
function parseTokenResponse(json) {
  if (!json || typeof json.access_token !== 'string' || typeof json.refresh_token !== 'string' || !Number.isFinite(json.expires_at)) return null;
  const athleteId = json.athlete && Number.isSafeInteger(json.athlete.id) ? json.athlete.id : undefined;
  return { accessToken: json.access_token, refreshToken: json.refresh_token, expiresAt: json.expires_at, athleteId };
}

function tokenNeedsRefresh(tokens, nowSec, skewSec = 300) {
  return !tokens || !(tokens.expiresAt - skewSec > nowSec);
}

module.exports = {
  AUTHORIZE_URL, SCOPE, STATE_TTL_MS,
  challengeResponse, parseEvent, actionFor, mapActivity, tombstone,
  buildAuthorizeUrl, newStateRecord, validateState, parseCallback, parseTokenResponse, tokenNeedsRefresh,
};
