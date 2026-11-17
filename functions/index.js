'use strict';
// Thin wiring around the pure modules in lib/. Everything with a decision in it is unit-tested there; this file only
// moves data between Firebase, Strava and Google. NOT exercised in the authoring environment (no deployed project,
// no Strava/Google credentials) — see README → "Verification status".

const crypto = require('node:crypto');
const admin = require('firebase-admin');
const { onRequest } = require('firebase-functions/v2/https');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { setGlobalOptions } = require('firebase-functions/v2');
const { defineSecret, defineString } = require('firebase-functions/params');

const strava = require('./lib/strava');
const places = require('./lib/places');
const { consume } = require('./lib/ratelimit');
const { authenticate } = require('./lib/http');
const reg = require('./lib/registrations');
const pr = require('./lib/passwordReset');

admin.initializeApp();
const db = admin.firestore();
const { FieldValue } = admin.firestore;

// Brazilian users → keep compute near them. (Choose the Firestore location to match when creating the database.)
setGlobalOptions({ region: 'southamerica-east1', maxInstances: 10 });

const STRAVA_CLIENT_SECRET = defineSecret('STRAVA_CLIENT_SECRET');
const STRAVA_VERIFY_TOKEN = defineSecret('STRAVA_VERIFY_TOKEN');
const PLACES_API_KEY = defineSecret('PLACES_API_KEY');
/** Keys the CPF → registration id and CPF/CREF → login alias HMACs. Long, random, never leaves the server. */
const REGISTRATION_SECRET = defineSecret('REGISTRATION_SECRET');
const STRAVA_CLIENT_ID = defineString('STRAVA_CLIENT_ID');
/** Known only after the subscription exists (the challenge handshake works without it): set it, redeploy. */
const STRAVA_SUBSCRIPTION_ID = defineString('STRAVA_SUBSCRIPTION_ID', { default: '' });
/** e.g. https://southamerica-east1-<project>.cloudfunctions.net */
const PUBLIC_FUNCTIONS_URL = defineString('PUBLIC_FUNCTIONS_URL');

const STRAVA_API = 'https://www.strava.com/api/v3';
const APP_SCHEME = 'fitcoach';

// ---------- helpers ----------

const verifiers = {
  verifyIdToken: (token) => admin.auth().verifyIdToken(token),
  verifyAppCheck: (token) => admin.appCheck().verifyToken(token),
};

function json(res, status, body) {
  res.set('Cache-Control', 'no-store');
  res.status(status).json(body);
}

/** POST + Firebase ID token + App Check, or the response has already been sent and `null` is returned. */
async function requireUser(req, res) {
  if (req.method !== 'POST') { json(res, 405, { error: 'method' }); return null; }
  const auth = await authenticate(req.headers, verifiers);
  if (!auth.ok) { json(res, auth.status, { error: auth.error }); return null; }
  return auth.uid;
}

async function isStudent(uid) {
  const user = await db.doc(`users/${uid}`).get();
  return user.exists && user.get('role') === 'student';
}

const tokensRef = (uid) => db.doc(`stravaTokens/${uid}`);           // no client rule matches → default deny
const linkRef = (uid) => db.doc(`students/${uid}/integrations/strava`);

async function stravaToken(body) {
  const response = await fetch('https://www.strava.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_id: STRAVA_CLIENT_ID.value(), client_secret: STRAVA_CLIENT_SECRET.value(), ...body }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) { const error = new Error(`strava token ${response.status}`); error.status = response.status; throw error; }
  return strava.parseTokenResponse(await response.json());
}

/** A valid access token for the student, refreshing (and persisting the rotated refresh token) when needed. */
async function accessTokenFor(uid) {
  const snapshot = await tokensRef(uid).get();
  if (!snapshot.exists) return null;
  let tokens = snapshot.data();
  if (strava.tokenNeedsRefresh(tokens, Math.floor(Date.now() / 1000))) {
    const refreshed = await stravaToken({ grant_type: 'refresh_token', refresh_token: tokens.refreshToken });
    if (!refreshed) return null;
    tokens = { ...tokens, ...refreshed, athleteId: tokens.athleteId };
    await tokensRef(uid).set(tokens);
  }
  return tokens.accessToken;
}

async function writeLink(uid, patch) {
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(linkRef(uid));
    const previous = existing.exists ? existing.data() : {};
    const now = new Date();
    tx.set(linkRef(uid), {
      id: 'strava', provider: 'strava', studentID: uid,
      isConnected: false,
      ...previous, ...patch,
      meta: { version: (previous.meta?.version || 0) + 1, updatedAt: now, lastWriterDeviceID: 'cloud-function' },
      _rev: (previous._rev || 0) + 1, _updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

/** Revoke at Strava (best effort), delete tokens and every imported activity, mark the link disconnected. */
async function disconnect(uid, { revoke }) {
  if (revoke) {
    const token = await accessTokenFor(uid).catch(() => null);
    if (token) {
      await fetch('https://www.strava.com/oauth/deauthorize', {
        method: 'POST', headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000),
      }).catch(() => {});
    }
  }
  await tokensRef(uid).delete();
  const collection = db.collection(`students/${uid}/externalActivities`);
  for (;;) {
    const batch = await collection.limit(400).get();
    if (batch.empty) break;
    const writer = db.batch();
    batch.docs.forEach((doc) => writer.delete(doc.ref));
    await writer.commit();
  }
  await writeLink(uid, { isConnected: false, externalAccountID: FieldValue.delete(), connectedAt: FieldValue.delete() });
}

// ---------- Strava: connect ----------

exports.stravaConnectStart = onRequest({}, async (req, res) => {
  const uid = await requireUser(req, res);
  if (!uid) return;
  if (!(await isStudent(uid))) return json(res, 403, { error: 'students-only' });

  const state = crypto.randomBytes(24).toString('hex');
  await db.doc(`stravaStates/${state}`).set(strava.newStateRecord(uid, Date.now()));
  json(res, 200, {
    url: strava.buildAuthorizeUrl({ clientId: STRAVA_CLIENT_ID.value(), redirectUri: `${PUBLIC_FUNCTIONS_URL.value()}/stravaCallback`, state }),
  });
});

exports.stravaCallback = onRequest({ secrets: [STRAVA_CLIENT_SECRET] }, async (req, res) => {
  const back = (status) => res.redirect(302, `${APP_SCHEME}://integrations/strava?status=${status}`);
  const parsed = strava.parseCallback(req.query);
  if (!parsed.ok) return back(parsed.reason === 'denied' ? 'denied' : 'error');

  // The state is single-use and was minted for exactly one signed-in user.
  const stateRef = db.doc(`stravaStates/${parsed.state}`);
  const verdict = await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(stateRef);
    const result = strava.validateState(snapshot.exists ? snapshot.data() : undefined, Date.now());
    if (snapshot.exists) tx.delete(stateRef);
    return result;
  });
  if (!verdict.ok) return back('error');
  const uid = verdict.uid;

  try {
    const tokens = await stravaToken({ grant_type: 'authorization_code', code: parsed.code });
    if (!tokens || !tokens.athleteId) return back('error');

    // One Strava account ↔ one student: the webhook resolves the student from the athlete id.
    const clash = await db.collectionGroup('integrations').where('externalAccountID', '==', String(tokens.athleteId)).limit(2).get();
    if (clash.docs.some((doc) => doc.ref.parent.parent.id !== uid)) return back('already-linked');

    await tokensRef(uid).set(tokens);
    await writeLink(uid, { isConnected: true, connectedAt: new Date(), externalAccountID: String(tokens.athleteId) });
    return back('connected');
  } catch (error) {
    console.error('strava connect failed', error.status || error.message);
    return back('error');
  }
});

exports.stravaDisconnect = onRequest({ secrets: [STRAVA_CLIENT_SECRET] }, async (req, res) => {
  const uid = await requireUser(req, res);
  if (!uid) return;
  await disconnect(uid, { revoke: true });
  json(res, 200, { ok: true });
});

// ---------- Strava: webhook ----------

exports.stravaWebhook = onRequest({ secrets: [STRAVA_VERIFY_TOKEN] }, async (req, res) => {
  if (req.method === 'GET') {
    const answer = strava.challengeResponse(req.query, STRAVA_VERIFY_TOKEN.value());
    return json(res, answer.status, answer.body);
  }
  if (req.method !== 'POST') return json(res, 405, { error: 'method' });

  const subscriptionId = STRAVA_SUBSCRIPTION_ID.value();
  if (!subscriptionId) return json(res, 503, { error: 'subscription-not-configured' });   // never accept unauthenticated events

  const parsed = strava.parseEvent(req.body, subscriptionId);
  if (parsed.ok) {
    // Only enqueue: Strava wants an answer within ~2 s. `create` is the dedupe (same event delivered twice → one doc).
    await db.doc(`stravaEvents/${parsed.id}`).create({ ...parsed.event, receivedAt: FieldValue.serverTimestamp() })
      .catch((error) => { if (error.code !== 6) throw error; });    // 6 = ALREADY_EXISTS
  }
  // Always 200: a forged/garbled event must not teach the sender anything, and Strava should not retry it.
  res.status(200).send('EVENT_RECEIVED');
});

exports.processStravaEvent = onDocumentCreated(
  { document: 'stravaEvents/{eventId}', secrets: [STRAVA_CLIENT_SECRET], retry: true },
  async (event) => {
    const stored = event.data.data();
    const action = strava.actionFor(stored);
    if (action === 'ignore') return;

    // Who is this athlete? Resolve the student from the *path* of the link, never from a field.
    const match = await db.collectionGroup('integrations')
      .where('externalAccountID', '==', String(stored.ownerId)).limit(1).get();
    const link = match.docs[0];
    if (!link || link.get('provider') !== 'strava' || link.get('isConnected') !== true) return;   // not (or no longer) connected
    const uid = link.ref.parent.parent.id;

    if (action === 'deauthorize') return disconnect(uid, { revoke: false });

    const ref = db.doc(`students/${uid}/externalActivities/strava-${stored.objectId}`);
    if (action === 'delete-activity') {
      await db.runTransaction(async (tx) => {
        const existing = await tx.get(ref);
        if (!existing.exists || existing.get('meta.deletedAt')) return;
        tx.set(ref, { ...strava.tombstone(existing.data(), new Date()), _rev: (existing.get('_rev') || 0) + 1, _updatedAt: FieldValue.serverTimestamp() });
      });
      return;
    }

    const token = await accessTokenFor(uid);
    if (!token) return;
    const response = await fetch(`${STRAVA_API}/activities/${stored.objectId}`, {
      headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000),
    });
    if (response.status === 404 || response.status === 403) return;     // private, deleted meanwhile, or scope not granted
    if (!response.ok) throw new Error(`strava activity ${response.status}`);   // transient → retry

    const activity = strava.mapActivity(await response.json(), { studentID: uid, ownerId: stored.ownerId, now: new Date() });
    if (!activity) return;
    await db.runTransaction(async (tx) => {
      const existing = await tx.get(ref);
      const version = existing.exists ? (existing.get('meta.version') || 0) + 1 : 1;
      tx.set(ref, {
        ...activity, meta: { ...activity.meta, version },
        _rev: (existing.exists ? existing.get('_rev') || 0 : 0) + 1, _updatedAt: FieldValue.serverTimestamp(),
        _mutationId: event.params.eventId,
      });
    });
  },
);

// ---------- Google Places proxy ----------

const PLACES_LIMIT = { limit: 30, windowMs: 60 * 60 * 1000 };

exports.searchGyms = onRequest({ secrets: [PLACES_API_KEY] }, async (req, res) => {
  const uid = await requireUser(req, res);
  if (!uid) return;

  const search = places.validateSearch(req.body);
  if (!search.ok) return json(res, 400, { error: `invalid-${search.reason}` });

  // The API is billed per call: bound what one account can spend.
  const counterRef = db.doc(`rateLimits/places-${uid}`);
  const verdict = await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(counterRef);
    const result = consume(snapshot.exists ? snapshot.data() : undefined, Date.now(), PLACES_LIMIT);
    tx.set(counterRef, result.next);
    return result;
  });
  if (!verdict.allowed) { res.set('Retry-After', String(verdict.retryAfterSeconds)); return json(res, 429, { error: 'rate-limited' }); }

  const request = places.buildNearbyRequest(search);
  const response = await fetch(request.url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': PLACES_API_KEY.value(), 'X-Goog-FieldMask': request.fieldMask },
    body: JSON.stringify(request.body),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) { console.error('places error', response.status); return json(res, 502, { error: 'upstream' }); }
  json(res, 200, { gyms: places.mapPlaces(await response.json()) });
});


// ---------- Students: registration, first access, login alias ----------
//
// The trainer registers a student (CPF + name). The student's first login repeats them; the backend answers "not found" for an
// unknown CPF and for a wrong name alike, so the screen can't be used to discover which CPFs exist. Accounts are created under an
// opaque HMAC login name (the CPF is never stored and never used as an identifier), and the password is checked by Firebase Auth.

const ATTEMPTS = { limit: 10, windowMs: 60 * 60 * 1000 };

async function appCheckOnly(req, res) {
  const token = req.headers['x-firebase-appcheck'];
  if (req.method !== 'POST') { json(res, 405, { error: 'method' }); return false; }
  try { await verifiers.verifyAppCheck(token); } catch { json(res, 401, { error: 'bad-app-check' }); return false; }
  return true;
}

/** Fixed-window limiter keyed by a hash of the caller's IP (never stored raw). */
async function underLimit(req, res, bucket, policy = ATTEMPTS) {
  const forwarded = String(req.headers['x-forwarded-for'] || req.ip || '').split(',')[0].trim();
  const ref = db.doc(`rateLimits/${bucket}-${crypto.createHash('sha256').update(forwarded).digest('hex').slice(0, 32)}`);
  const verdict = await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    const result = reg.consumeAttempt(snapshot.exists ? snapshot.data() : undefined, Date.now(), policy);
    tx.set(ref, result.next);
    return result;
  });
  if (!verdict.allowed) { res.set('Retry-After', String(verdict.retryAfterSeconds)); json(res, 429, { error: 'rate-limited' }); return false; }
  return true;
}

exports.registerStudent = onRequest({ secrets: [REGISTRATION_SECRET] }, async (req, res) => {
  const uid = await requireUser(req, res);
  if (!uid) return;
  const trainer = await db.doc(`users/${uid}`).get();
  if (!trainer.exists || trainer.get('role') !== 'trainer') return json(res, 403, { error: 'trainers-only' });

  const cpf = reg.normalizeCpf(req.body?.cpf);
  const fullName = reg.normalizeName(req.body?.fullName);
  if (!cpf || !fullName) return json(res, 400, { error: 'invalid' });

  const id = reg.registrationKey(REGISTRATION_SECRET.value(), cpf);
  const now = new Date();
  try {
    await db.doc(`registrations/${id}`).create({
      id, trainerID: uid, fullName, cpfMasked: reg.maskCpf(cpf), status: 'invited', createdAt: now,
      meta: { version: 1, updatedAt: now, lastWriterDeviceID: 'cloud-function' }, _rev: 1, _updatedAt: FieldValue.serverTimestamp(),
    });
  } catch (error) {
    if (error.code === 6) return json(res, 409, { error: 'duplicate' });     // 6 = ALREADY_EXISTS (any trainer)
    throw error;
  }
  json(res, 200, { id, fullName, cpfMasked: reg.maskCpf(cpf), createdAt: now.getTime() / 1000 });
});

exports.claimRegistration = onRequest({ secrets: [REGISTRATION_SECRET] }, async (req, res) => {
  if (!(await appCheckOnly(req, res)) || !(await underLimit(req, res, 'claim'))) return;
  const secret = REGISTRATION_SECRET.value();
  const cpf = reg.normalizeCpf(req.body?.cpf);
  const fullName = typeof req.body?.fullName === 'string' ? req.body.fullName : '';
  const notFound = () => json(res, 404, { error: 'not-found' });
  if (!cpf) return notFound();

  const snapshot = await db.doc(`registrations/${reg.registrationKey(secret, cpf)}`).get();
  const decision = reg.decideClaim(snapshot.exists ? snapshot.data() : undefined, fullName);
  if (!decision.ok) return json(res, decision.status, { error: decision.error });

  const { token, record } = reg.newToken(snapshot.id, Date.now());
  // The login alias is derived now (we have the CPF in hand) and kept server-side with the one-time token; the CPF itself is not stored.
  await db.doc(`claimTokens/${record.tokenHash}`).set({ ...record, alias: reg.loginAlias(secret, cpf) });
  const trainer = await db.doc(`users/${snapshot.get('trainerID')}`).get();
  json(res, 200, { registrationId: snapshot.id, trainerName: trainer.get('displayName') || null, token });
});

exports.completeRegistration = onRequest({ secrets: [REGISTRATION_SECRET] }, async (req, res) => {
  if (!(await appCheckOnly(req, res)) || !(await underLimit(req, res, 'complete'))) return;
  const valid = reg.validateProfile(req.body);
  if (!valid.ok) return json(res, 400, { error: `invalid-${valid.reason}` });

  const tokenRef = db.doc(`claimTokens/${reg.tokenHash(req.body.token)}`);
  const tokenSnapshot = await tokenRef.get();
  const verdict = reg.validateToken(tokenSnapshot.exists ? tokenSnapshot.data() : undefined, Date.now());
  if (!verdict.ok) return json(res, 404, { error: 'not-found' });

  const registrationRef = db.doc(`registrations/${verdict.registrationId}`);
  const registration = await registrationRef.get();
  if (!registration.exists || registration.get('status') !== 'invited') return json(res, 409, { error: 'already-claimed' });

  let user;
  try {
    user = await admin.auth().createUser({ email: tokenSnapshot.get('alias'), password: valid.password, displayName: registration.get('fullName') });
  } catch (error) {
    if (error.code === 'auth/email-already-exists') return json(res, 409, { error: 'already-claimed' });
    throw error;
  }

  try {
    const now = new Date();
    const trainerID = registration.get('trainerID');
    await db.runTransaction(async (tx) => {
      const fresh = await tx.get(registrationRef);
      if (fresh.get('status') !== 'invited') throw new Error('already-claimed');
      tx.update(registrationRef, {
        status: 'active', studentID: user.uid, ...valid.profile,
        'meta.version': (fresh.get('meta.version') || 0) + 1, 'meta.updatedAt': now, _rev: (fresh.get('_rev') || 0) + 1, _updatedAt: FieldValue.serverTimestamp(),
      });
      // `users/{uid}`: role + trainer are written ONLY here (rules forbid clients from changing them).
      tx.set(db.doc(`users/${user.uid}`), {
        id: user.uid, role: 'student', displayName: registration.get('fullName'), trainerID, createdAt: now,
        age: valid.profile.age, heightCm: valid.profile.heightCm, weightKg: valid.profile.weightKg,
        meta: { version: 1, updatedAt: now, lastWriterDeviceID: 'cloud-function' }, _rev: 1, _updatedAt: FieldValue.serverTimestamp(),
      });
      tx.set(db.doc(`trainerLinks/${trainerID}_${user.uid}`), { trainerID, studentID: user.uid, status: 'active', createdAt: now });
      tx.delete(tokenRef);                                                    // one use
    });
  } catch (error) {
    await admin.auth().deleteUser(user.uid).catch(() => {});                  // don't leave a half-made account behind
    if (error.message === 'already-claimed') return json(res, 409, { error: 'already-claimed' });
    throw error;
  }
  json(res, 200, { userId: user.uid, displayName: registration.get('fullName'), customToken: await admin.auth().createCustomToken(user.uid) });
});

/** CPF/CREF → opaque login name. Computed for ANY input, with no lookup: it reveals nothing about who is registered. */
exports.loginAlias = onRequest({ secrets: [REGISTRATION_SECRET] }, async (req, res) => {
  if (!(await appCheckOnly(req, res)) || !(await underLimit(req, res, 'alias', { limit: 60, windowMs: ATTEMPTS.windowMs }))) return;
  const raw = typeof req.body?.identifier === 'string' ? req.body.identifier.trim().slice(0, 200) : '';
  const identifier = reg.normalizeCpf(raw) || reg.normalizeCref(raw) || `raw:${raw}`;
  json(res, 200, { alias: reg.loginAlias(REGISTRATION_SECRET.value(), identifier) });
});

/**
 * Step 1 of "forgot password": CPF + the e-mail registered at first access. The answer is ALWAYS `{ ok: true }` — match, mismatch, unknown
 * CPF or cooldown look the same, so this can't be used to find out who is registered. Only a match writes the code and queues an e-mail
 * (the `mail` collection is read by the "Trigger Email from Firestore" extension, or any worker you point at it; clients can't touch it).
 */
exports.requestPasswordReset = onRequest({ secrets: [REGISTRATION_SECRET] }, async (req, res) => {
  if (!(await appCheckOnly(req, res)) || !(await underLimit(req, res, 'reset-request'))) return;
  const secret = REGISTRATION_SECRET.value();
  const cpf = reg.normalizeCpf(req.body?.cpf);
  const email = pr.normalizeEmail(req.body?.email);
  if (!cpf || !pr.validEmailShape(email)) return json(res, 400, { error: 'invalid' });      // malformed input only — says nothing about registrations

  const id = reg.registrationKey(secret, cpf);
  const registration = await db.doc(`registrations/${id}`).get();
  const decision = pr.decideRequest(registration.exists ? registration.data() : undefined, email);
  if (decision.ok) {
    const resetRef = db.doc(`passwordResets/${id}`);
    const existing = await resetRef.get();
    const now = Date.now();
    if (pr.canRequest(existing.exists ? existing.data() : undefined, now)) {
      const code = pr.newResetCode();
      await resetRef.set(pr.newResetRecord(secret, id, code, now));
      await db.collection('mail').add({ to: [decision.to], message: pr.resetMessage({ name: registration.get('fullName'), code }) });
    }
  }
  json(res, 200, { ok: true });
});

/** Step 2: the code from the e-mail + the new password. Wrong, expired and unknown all answer the same; five misses lock the code. */
exports.confirmPasswordReset = onRequest({ secrets: [REGISTRATION_SECRET] }, async (req, res) => {
  if (!(await appCheckOnly(req, res)) || !(await underLimit(req, res, 'reset-confirm'))) return;
  const secret = REGISTRATION_SECRET.value();
  if (!pr.validateNewPassword(req.body?.password)) return json(res, 400, { error: 'invalid-password' });
  const cpf = reg.normalizeCpf(req.body?.cpf);
  if (!cpf) return json(res, 400, { error: 'invalid-code' });

  const id = reg.registrationKey(secret, cpf);
  const resetRef = db.doc(`passwordResets/${id}`);
  const outcome = await db.runTransaction(async (tx) => {
    const [reset, registration] = await Promise.all([tx.get(resetRef), tx.get(db.doc(`registrations/${id}`))]);
    const stored = registration.exists ? registration.data() : undefined;
    if (!stored || stored.status !== 'active' || typeof stored.studentID !== 'string') return { ok: false, reason: 'unknown' };
    const verdict = pr.checkCode(reset.exists ? reset.data() : undefined, secret, id, req.body?.code, Date.now());
    if (!verdict.ok) {
      if (verdict.reason === 'wrong') tx.update(resetRef, { attempts: FieldValue.increment(1) });
      return verdict;
    }
    tx.delete(resetRef);                                                                    // one use
    return { ok: true, uid: stored.studentID };
  });
  if (!outcome.ok) return outcome.reason === 'locked' ? json(res, 429, { error: 'locked' }) : json(res, 400, { error: 'invalid-code' });

  await admin.auth().updateUser(outcome.uid, { password: req.body.password });
  await admin.auth().revokeRefreshTokens(outcome.uid);                                      // whoever had the old password is signed out
  json(res, 200, { ok: true });
});

