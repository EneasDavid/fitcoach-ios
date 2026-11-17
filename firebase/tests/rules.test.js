// Firestore security-rules tests, run against the local emulator:
//
//   cd firebase && npm install && npm test
//
// Writes go through `gatewayWrite`, which mirrors App/Firebase/FirestoreRemoteGateway.swift exactly:
// one transaction that reads the document, then writes payload + `_rev`, `_mutationId`, `_updatedAt = serverTimestamp()`.
// Testing through the same shape (including the transactional *read of a document that doesn't exist yet*) is what
// catches rule/gateway mismatches.
import { readFileSync } from 'node:fs';
import { describe, it, before, after, beforeEach } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  doc, collection, getDoc, getDocs, setDoc, deleteDoc, query, where, documentId, runTransaction, serverTimestamp, Timestamp,
} from 'firebase/firestore';

let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-fitcoach',
    firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
});
after(async () => { await env.cleanup(); });
beforeEach(async () => {
  await env.clearFirestore();
  // Server-side state a Cloud Function / admin would have created.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users/s1'), { id: 's1', role: 'student', displayName: 'Student One' });
    await setDoc(doc(db, 'users/s2'), { id: 's2', role: 'student', displayName: 'Student Two' });
    await setDoc(doc(db, 'users/t1'), { id: 't1', role: 'trainer', displayName: 'Trainer One' });
    await setDoc(doc(db, 'users/t2'), { id: 't2', role: 'trainer', displayName: 'Trainer Two' });
    await setDoc(doc(db, 'trainerLinks/t1_s1'), { trainerID: 't1', studentID: 's1', status: 'active' });
    await setDoc(doc(db, 'trainerLinks/t1_s3'), { trainerID: 't1', studentID: 's3', status: 'revoked' });
    await setDoc(doc(db, 'plans/p1'), plan({ id: 'p1' }, 1, { raw: true }));
    await setDoc(doc(db, 'students/s1/workoutLogs/l1'), log({ id: 'l1' }, 1, { raw: true }));
    await setDoc(doc(db, 'students/s1/bodyCheckpoints/b1'), checkpoint({ id: 'b1' }, 1, { raw: true }));
    await setDoc(doc(db, 'exerciseCache/squat'), { name: 'Back Squat' });
    // Server-written (Admin SDK) feed/integration documents.
    await setDoc(doc(db, 'students/s1/externalActivities/strava-1'), activity({ id: 'strava-1' }, 1, { raw: true }));
    await setDoc(doc(db, 'students/s1/integrations/strava'), { id: 'strava', provider: 'strava', studentID: 's1', isConnected: true, externalAccountID: '777', _rev: 1 });
    await setDoc(doc(db, 'stravaTokens/s1'), { accessToken: 'secret', refreshToken: 'secret' });
    await setDoc(doc(db, 'stravaEvents/e1'), { objectId: 1 });
    await setDoc(doc(db, 'students/s1/posts/post-1'), post({ id: 'post-1' }, 1, { raw: true }));
    await setDoc(doc(db, 'registrations/reg-1'), { id: 'reg-1', trainerID: 't1', fullName: 'Maria Souza', cpfMasked: '***.982.247-**', status: 'active', studentID: 's1', email: 'm@x.co', age: 30, gender: 'female', _rev: 1 });
    await setDoc(doc(db, 'trainers/t1/nicknames/reg-1'), { id: 'reg-1', trainerID: 't1', nickname: 'Tigresa 7h', meta: { version: 1, updatedAt: Timestamp.now(), lastWriterDeviceID: 'd' }, _rev: 1, _updatedAt: Timestamp.now(), _mutationId: 'seed' });
    await setDoc(doc(db, 'claimTokens/abc'), { registrationId: 'reg-1', alias: 'x@students.fitcoach.invalid' });
  });
});

// ---------- payloads shaped like the Swift entities ----------
const now = () => Timestamp.now();
// Documents seeded with `raw` bypass the rules, so they must carry the gateway's bookkeeping themselves.
const book = (data, opts) => (opts.raw ? { ...data, _rev: 1, _mutationId: 'seed', _updatedAt: Timestamp.now() } : data);
const meta = (version) => ({ version, updatedAt: now(), lastWriterDeviceID: 'device-1' });

/** Fields as `SyncCoding.fields(entity)` produces them (dates are Timestamps after the gateway converts them). */
function plan(over = {}, version = 1, opts = {}) {
  return book({
    id: 'p-new', trainerID: 't1', studentID: 's1', name: 'Hypertrophy', isActive: true, startDate: now(),
    targetSessionsPerWeek: 3, templates: [{ id: 'a', label: 'A', order: 0, blocks: [] }], meta: meta(version), ...over,
  }, opts);
}
function log(over = {}, version = 1, opts = {}) {
  return book({
    id: 'l-new', planID: 'p1', templateID: 'a', templateLabel: 'A', studentID: 's1', status: 'inProgress',
    startedAt: now(), rotationIndex: 0, blocks: [], meta: meta(version), ...over,
  }, opts);
}
function coachedLog(over = {}, version = 1, opts = {}) {
  return log({ id: 'c-new', coachedBy: 't1', ...over }, version, opts);
}
function checkpoint(over = {}, version = 1, opts = {}) {
  return book({
    id: 'b-new', studentID: 's1', trainerID: 't1', recordedAt: now(), bodyWeightKg: 80, bodyFatPercent: 18, meta: meta(version), ...over,
  }, opts);
}
function sharedPhoto(over = {}, version = 1, opts = {}) {
  return book({ id: 'photo-1', studentID: 's1', takenAt: now(), caption: 'Treino C · Pernas', photo: 'AAECAw==', meta: meta(version), ...over }, opts);
}
function trainerProfile(over = {}, version = 1, opts = {}) {
  return book({ id: 't1', displayName: 'Trainer One', cref: '012345-G/AL', photo: 'AAECAw==', meta: meta(version), ...over }, opts);
}
function activity(over = {}, version = 1, opts = {}) {
  return book({
    id: 'strava-new', studentID: 's1', source: 'strava', externalID: '1', sportType: 'Run', name: 'Morning Run', startedAt: now(),
    movingSeconds: 1800, elapsedSeconds: 1900, meta: meta(version), ...over,
  }, opts);
}
function post(over = {}, version = 1, opts = {}) {
  return book({
    id: 'post-new', studentID: 's1', kind: 'personalRecord', createdAt: now(), title: 'New PR · Bench Press', subtitle: '85 kg × 5',
    stats: [{ label: 'Sets', value: '9' }], tracks: [{ title: 'Eye of the Tiger', artist: 'Survivor', plays: 2 }], meta: meta(version), ...over,
  }, opts);
}
function prefs(over = {}, version = 1) {
  return { studentID: 's1', shareStravaWithTrainer: false, includeMusicInPosts: false, meta: meta(version), ...over };
}
async function configure({ killSwitchOn, studentShares }) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    if (killSwitchOn !== undefined) await setDoc(doc(db, 'config/features'), { stravaCoachSharing: killSwitchOn });
    if (studentShares !== undefined) await setDoc(doc(db, 'students/s1/sharing/preferences'), { ...prefs({ shareStravaWithTrainer: studentShares }), _rev: 1 });
  });
}
function checkIn(over = {}, version = 1) {
  return { id: 'c-new', studentID: 's1', provider: 'geofence', arrivedAt: now(), meta: meta(version), ...over };
}

/** Mirror of FirestoreRemoteGateway.apply(.upsert): read, then full-replace with server bookkeeping. */
async function gatewayWrite(db, path, payload, { stamped = true } = {}) {
  const ref = doc(db, path);
  return runTransaction(db, async (tx) => {
    const snap = await tx.get(ref);
    const rev = (snap.exists() ? snap.data()._rev : 0) ?? 0;
    tx.set(ref, {
      ...payload, _rev: rev + 1, _mutationId: crypto.randomUUID(),
      // "Not server time" must be unmistakable: Timestamp.now() can land on the very millisecond of request.time and pass `stamped()` by chance.
      _updatedAt: stamped ? serverTimestamp() : Timestamp.fromMillis(Date.now() - 60_000),
    });
  });
}

const as = (uid) => env.authenticatedContext(uid).firestore();
const anonymous = () => env.unauthenticatedContext().firestore();

describe('default deny & authentication', () => {
  it('rejects every read when signed out', async () => {
    for (const path of ['users/s1', 'plans/p1', 'students/s1/workoutLogs/l1', 'exerciseCache/squat', 'trainerLinks/t1_s1']) {
      await assertFails(getDoc(doc(anonymous(), path)));
    }
  });
  it('denies collections the rules do not know about', async () => {
    await assertFails(getDoc(doc(as('s1'), 'secrets/x')));
    await assertFails(setDoc(doc(as('s1'), 'secrets/x'), { a: 1 }));
  });
  it('denies writes when signed out', async () => {
    await assertFails(gatewayWrite(anonymous(), 'students/s1/workoutLogs/l-new', log()));
  });
});

describe('users', () => {
  it('self and a linked trainer can read; strangers, other students and revoked-link trainers cannot', async () => {
    await assertSucceeds(getDoc(doc(as('s1'), 'users/s1')));
    await assertSucceeds(getDoc(doc(as('t1'), 'users/s1')));
    await assertFails(getDoc(doc(as('s2'), 'users/s1')));
    await assertFails(getDoc(doc(as('t2'), 'users/s1')));
    await assertFails(getDoc(doc(as('t1'), 'users/s3')));      // link exists but is revoked
  });
  it('allows creating your own profile as student or trainer, through the gateway', async () => {
    await assertSucceeds(gatewayWrite(as('n1'), 'users/n1', { id: 'n1', role: 'student', displayName: 'New' }));
    await assertSucceeds(gatewayWrite(as('n2'), 'users/n2', { id: 'n2', role: 'trainer', displayName: 'New' }));
  });
  it('rejects self-assigned roles outside the allowed set, a pre-set trainer link, and other people’s profiles', async () => {
    await assertFails(gatewayWrite(as('n1'), 'users/n1', { id: 'n1', role: 'admin', displayName: 'x' }));
    await assertFails(gatewayWrite(as('n1'), 'users/n1', { id: 'n1', role: 'student', trainerID: 't1' }));
    await assertFails(gatewayWrite(as('n1'), 'users/someone-else', { id: 'x', role: 'student' }));
  });
  it('rejects writes that were not stamped with server time', async () => {
    await assertFails(gatewayWrite(as('n1'), 'users/n1', { id: 'n1', role: 'student' }, { stamped: false }));
  });
  it('lets you edit your profile but never change role or trainer link', async () => {
    const db = as('s1');
    await assertSucceeds(gatewayWrite(db, 'users/s1', { id: 's1', role: 'student', displayName: 'Renamed' }));
    await assertFails(gatewayWrite(db, 'users/s1', { id: 's1', role: 'trainer', displayName: 'Renamed' }));
    await assertFails(gatewayWrite(db, 'users/s1', { id: 's1', role: 'student', trainerID: 't2' }));
  });
  it('keeps the height, weight and age on the account in a human range', async () => {
    const db = as('s1');
    await assertSucceeds(gatewayWrite(db, 'users/s1', { id: 's1', role: 'student', heightCm: 178, weightKg: 82.5, age: 29 }));
    for (const bad of [{ heightCm: 99 }, { heightCm: 251 }, { heightCm: '178' }, { weightKg: 19 }, { weightKg: 401 }, { age: 11 }, { age: 101 }, { age: 29.5 }]) {
      await assertFails(gatewayWrite(db, 'users/s1', { id: 's1', role: 'student', ...bad }));
    }
  });
  it('forbids deletes', async () => {
    await assertFails(deleteDoc(doc(as('s1'), 'users/s1')));
  });
});

describe('trainerLinks', () => {
  it('are readable by the two parties only', async () => {
    await assertSucceeds(getDoc(doc(as('t1'), 'trainerLinks/t1_s1')));
    await assertSucceeds(getDoc(doc(as('s1'), 'trainerLinks/t1_s1')));
    await assertFails(getDoc(doc(as('s2'), 'trainerLinks/t1_s1')));
    await assertFails(getDoc(doc(as('t2'), 'trainerLinks/t1_s1')));
  });
  it('can be listed by the trainer for their own roster (query constrained to themselves)', async () => {
    const q = query(collection(as('t1'), 'trainerLinks'), where('trainerID', '==', 't1'), where('status', '==', 'active'));
    const snap = await assertSucceeds(getDocs(q));
    assert(snap.size === 1);
    await assertFails(getDocs(query(collection(as('t1'), 'trainerLinks'), where('trainerID', '==', 't2'))));
  });
  it('cannot be written by any client — not even the trainer or the student', async () => {
    await assertFails(setDoc(doc(as('t1'), 'trainerLinks/t1_s2'), { trainerID: 't1', studentID: 's2', status: 'active' }));
    await assertFails(setDoc(doc(as('s2'), 'trainerLinks/t1_s2'), { trainerID: 't1', studentID: 's2', status: 'active' }));
    await assertFails(setDoc(doc(as('s1'), 'trainerLinks/t1_s1'), { trainerID: 't1', studentID: 's1', status: 'revoked' }));
  });
});

describe('plans', () => {
  it('are readable by the assigned student and the owning trainer only', async () => {
    await assertSucceeds(getDoc(doc(as('s1'), 'plans/p1')));
    await assertSucceeds(getDoc(doc(as('t1'), 'plans/p1')));
    await assertFails(getDoc(doc(as('s2'), 'plans/p1')));
    await assertFails(getDoc(doc(as('t2'), 'plans/p1')));
  });
  it('can be listed only with a query that proves ownership (what the inbound listeners use)', async () => {
    await assertSucceeds(getDocs(query(collection(as('s1'), 'plans'), where('studentID', '==', 's1'))));
    await assertSucceeds(getDocs(query(collection(as('t1'), 'plans'), where('trainerID', '==', 't1'))));
    await assertFails(getDocs(collection(as('s1'), 'plans')));                                   // unconstrained
    await assertFails(getDocs(query(collection(as('s2'), 'plans'), where('studentID', '==', 's1'))));
  });
  it('lets a linked trainer create a plan through the gateway (including the transactional read of the not-yet-existing doc)', async () => {
    await assertSucceeds(gatewayWrite(as('t1'), 'plans/p-new', plan()));
  });
  it('probing a plan id reveals nothing: an existing plan is denied, an unused id simply reads as empty', async () => {
    await assertFails(getDoc(doc(as('s2'), 'plans/p1')));
    const probe = await assertSucceeds(getDoc(doc(as('s2'), 'plans/unused-id')));
    assert(!probe.exists());
  });
  it('rejects plans from trainers who are not linked, revoked, impersonating, or students', async () => {
    await assertFails(gatewayWrite(as('t2'), 'plans/p-new', plan({ trainerID: 't2' })));              // no link to s1
    await assertFails(gatewayWrite(as('t1'), 'plans/p-new', plan({ studentID: 's3' })));              // revoked link
    await assertFails(gatewayWrite(as('t1'), 'plans/p-new', plan({ trainerID: 't2' })));              // claims to be t2
    await assertFails(gatewayWrite(as('s1'), 'plans/p-new', plan({ trainerID: 's1' })));              // a student "trainer"
  });
  it('validates shape and range', async () => {
    const db = as('t1');
    await assertFails(gatewayWrite(db, 'plans/p-new', plan({ name: '' })));
    await assertFails(gatewayWrite(db, 'plans/p-new', plan({ name: 'x'.repeat(121) })));
    await assertFails(gatewayWrite(db, 'plans/p-new', plan({ targetSessionsPerWeek: 0 })));
    await assertFails(gatewayWrite(db, 'plans/p-new', plan({ targetSessionsPerWeek: 8 })));
    await assertFails(gatewayWrite(db, 'plans/p-new', plan({ targetSessionsPerWeek: 3.5 })));
    await assertFails(gatewayWrite(db, 'plans/p-new', plan({ templates: Array.from({ length: 15 }, (_, i) => ({ id: `t${i}` })) })));
    await assertFails(gatewayWrite(db, 'plans/p-new', plan({ templates: 'nope' })));
  });
  it('rejects writes not stamped with server time', async () => {
    await assertFails(gatewayWrite(as('t1'), 'plans/p-new', plan(), { stamped: false }));
  });
  it('lets the owner update with an advancing version, but not replay an old one or reassign owner/student', async () => {
    const db = as('t1');
    await assertSucceeds(gatewayWrite(db, 'plans/p1', plan({ id: 'p1', name: 'Edited' }, 2)));
    await assertFails(gatewayWrite(db, 'plans/p1', plan({ id: 'p1', name: 'Stale' }, 2)));          // same version again
    await assertFails(gatewayWrite(db, 'plans/p1', plan({ id: 'p1', studentID: 's2' }, 9)));
    await assertFails(gatewayWrite(db, 'plans/p1', plan({ id: 'p1', trainerID: 't2' }, 9)));
  });
  it('does not let the student or another trainer edit, and forbids deletes', async () => {
    await assertFails(gatewayWrite(as('s1'), 'plans/p1', plan({ id: 'p1', name: 'Mine now' }, 5)));
    await assertFails(gatewayWrite(as('t2'), 'plans/p1', plan({ id: 'p1', name: 'Mine now' }, 5)));
    await assertFails(deleteDoc(doc(as('t1'), 'plans/p1')));
  });
  it('supports tombstones (soft delete) as an ordinary version-advancing update', async () => {
    await assertSucceeds(gatewayWrite(as('t1'), 'plans/p1', plan({ id: 'p1', meta: { ...meta(2), deletedAt: now() } }, 2)));
  });
});

describe('workout logs', () => {
  const path = (id) => `students/s1/workoutLogs/${id}`;

  it('the student creates, reads and updates their own; the linked trainer reads but never writes', async () => {
    await assertSucceeds(gatewayWrite(as('s1'), path('l-new'), log()));
    await assertSucceeds(getDoc(doc(as('s1'), path('l1'))));
    await assertSucceeds(getDoc(doc(as('t1'), path('l1'))));
    await assertFails(gatewayWrite(as('t1'), path('l-t'), log({ id: 'l-t' })));
  });
  it('hides logs from other students, unlinked trainers and revoked-link trainers', async () => {
    await assertFails(getDoc(doc(as('s2'), path('l1'))));
    await assertFails(getDoc(doc(as('t2'), path('l1'))));
    await assertFails(getDoc(doc(as('t1'), 'students/s3/workoutLogs/x')));
  });
  it('rejects writing into someone else’s partition or claiming another student', async () => {
    await assertFails(gatewayWrite(as('s2'), path('l-x'), log({ id: 'l-x' })));
    await assertFails(gatewayWrite(as('s1'), path('l-x'), log({ id: 'l-x', studentID: 's2' })));
  });
  it('validates status, id, size limits and RPE (1…10, integer)', async () => {
    const db = as('s1');
    await assertFails(gatewayWrite(db, path('l-new'), log({ status: 'finished' })));
    await assertFails(gatewayWrite(db, path('l-new'), log({ id: 'different-from-doc-id' })));
    await assertFails(gatewayWrite(db, path('l-new'), log({ blocks: Array.from({ length: 41 }, () => ({})) })));
    await assertFails(gatewayWrite(db, path('l-new'), log({ feedbackNote: 'x'.repeat(2001) })));
    for (const rpe of [0, 11, -1, 7.5]) {
      await assertFails(gatewayWrite(db, path('l-new'), log({ status: 'completed', sessionRPE: rpe })));
    }
    for (const rpe of [1, 7, 10]) {
      await assertSucceeds(gatewayWrite(db, path(`l-rpe${rpe}`), log({ id: `l-rpe${rpe}`, status: 'completed', sessionRPE: rpe })));
    }
  });
  it('requires strictly advancing versions and an immutable owner/plan', async () => {
    const db = as('s1');
    await assertSucceeds(gatewayWrite(db, path('l1'), log({ id: 'l1', status: 'completed', sessionRPE: 8 }, 2)));
    await assertFails(gatewayWrite(db, path('l1'), log({ id: 'l1', status: 'completed' }, 2)));       // replayed version
    await assertFails(gatewayWrite(db, path('l1'), log({ id: 'l1', planID: 'other-plan' }, 9)));
  });
  it('forbids deletes and writes without server time', async () => {
    await assertFails(deleteDoc(doc(as('s1'), path('l1'))));
    await assertFails(gatewayWrite(as('s1'), path('l-new'), log(), { stamped: false }));
  });
  it('keeps a log written offline for days valid: the client timestamp inside meta is free, only _updatedAt is server-bound', async () => {
    const old = { ...log(), startedAt: Timestamp.fromDate(new Date('2024-01-01')), meta: { ...meta(1), updatedAt: Timestamp.fromDate(new Date('2024-01-01')) } };
    await assertSucceeds(gatewayWrite(as('s1'), path('l-new'), old));
  });
});

describe('check-ins', () => {
  const path = (id) => `students/s1/checkIns/${id}`;
  it('are written by the student and readable by the student and linked trainer', async () => {
    await assertSucceeds(gatewayWrite(as('s1'), path('c-new'), checkIn()));
    await assertSucceeds(getDoc(doc(as('t1'), path('c-new'))));
    await assertFails(getDoc(doc(as('s2'), path('c-new'))));
    await assertFails(gatewayWrite(as('t1'), path('c-t'), checkIn({ id: 'c-t' })));
    await assertFails(gatewayWrite(as('s1'), path('c-x'), checkIn({ id: 'c-x', studentID: 's2' })));
  });
});

describe('body-composition checkpoints', () => {
  const path = (id) => `students/s1/bodyCheckpoints/${id}`;
  it('are created by the linked trainer and readable by the student', async () => {
    await assertSucceeds(gatewayWrite(as('t1'), path('b-new'), checkpoint()));
    await assertSucceeds(getDoc(doc(as('s1'), path('b1'))));
    await assertSucceeds(getDoc(doc(as('t1'), path('b1'))));
  });
  it('are not writable by the student, an unlinked trainer, or a trainer claiming another identity', async () => {
    await assertFails(gatewayWrite(as('s1'), path('b-new'), checkpoint({ trainerID: 's1' })));
    await assertFails(gatewayWrite(as('t2'), path('b-new'), checkpoint({ trainerID: 't2' })));
    await assertFails(gatewayWrite(as('t1'), path('b-new'), checkpoint({ trainerID: 't2' })));
    await assertFails(gatewayWrite(as('t1'), path('b-new'), checkpoint({ studentID: 's2' })));
    await assertFails(getDoc(doc(as('s2'), path('b1'))));
  });
  it('rejects physiologically impossible values', async () => {
    const db = as('t1');
    for (const bad of [{ bodyWeightKg: 19 }, { bodyWeightKg: 401 }, { bodyFatPercent: 1 }, { bodyFatPercent: 61 }, { bodyFatPercent: 'high' }]) {
      await assertFails(gatewayWrite(db, path('b-new'), checkpoint(bad)));
    }
    await assertSucceeds(gatewayWrite(db, path('b-edge-low'), checkpoint({ id: 'b-edge-low', bodyWeightKg: 20, bodyFatPercent: 2 })));
    await assertSucceeds(gatewayWrite(db, path('b-edge-high'), checkpoint({ id: 'b-edge-high', bodyWeightKg: 400, bodyFatPercent: 60 })));
  });
  it('needs only the weight: a bioimpedance reading is optional, and so is every value on it', async () => {
    const db = as('t1');
    await assertSucceeds(gatewayWrite(db, path('b-weight-only'), { id: 'b-weight-only', studentID: 's1', trainerID: 't1', recordedAt: now(), bodyWeightKg: 80, meta: meta(1) }));
    await assertSucceeds(gatewayWrite(db, path('b-null-fat'), checkpoint({ id: 'b-null-fat', bodyFatPercent: null })));
    await assertSucceeds(gatewayWrite(db, path('b-full'), checkpoint({
      id: 'b-full', bodyFatPercent: 18.4, measuredFatMassKg: 14.7, measuredLeanMassKg: 65.3, skeletalMuscleMassKg: 36.2, bodyWaterPercent: 57.1,
      visceralFatLevel: 7, boneMassKg: 3.1, basalMetabolicRateKcal: 1850, metabolicAge: 27, waistCm: 84.5, hipCm: 98, notes: 'After 8 weeks.',
    })));
  });
  it('rejects impossible bioimpedance values, wrong types, and masses larger than the person', async () => {
    const db = as('t1');
    for (const bad of [
      { bodyWaterPercent: 20 }, { bodyWaterPercent: 90 }, { visceralFatLevel: 0 }, { visceralFatLevel: 61 }, { visceralFatLevel: 7.5 },
      { boneMassKg: 0.1 }, { boneMassKg: 11 }, { basalMetabolicRateKcal: 100 }, { basalMetabolicRateKcal: 7000 }, { metabolicAge: 4 }, { metabolicAge: 121 },
      { waistCm: 30 }, { waistCm: 300 }, { hipCm: 'wide' }, { skeletalMuscleMassKg: 200 }, { skeletalMuscleMassKg: 'a lot' },
      { measuredFatMassKg: 80 }, { measuredFatMassKg: 90 }, { measuredLeanMassKg: 81 }, { skeletalMuscleMassKg: 81 }, { notes: 'x'.repeat(501) }, { notes: 42 },
    ]) {
      await assertFails(gatewayWrite(db, path('b-new'), checkpoint(bad)));
    }
  });
  it('can be corrected by the owning trainer with an advancing version only', async () => {
    await assertSucceeds(gatewayWrite(as('t1'), path('b1'), checkpoint({ id: 'b1', bodyFatPercent: 17 }, 2)));
    await assertFails(gatewayWrite(as('t1'), path('b1'), checkpoint({ id: 'b1', bodyFatPercent: 16 }, 2)));
    await assertFails(gatewayWrite(as('s1'), path('b1'), checkpoint({ id: 'b1', bodyFatPercent: 10 }, 9)));
    await assertFails(deleteDoc(doc(as('t1'), path('b1'))));
  });
});

describe('server-only collections (password reset codes, the e-mail outbox, claim tokens, rate limits)', () => {
  it('can be neither read nor written by any client, trainer or student', async () => {
    for (const path of ['passwordResets/reg-1', 'mail/m1', 'claimTokens/abc', 'rateLimits/reset-request-1']) {
      for (const uid of ['s1', 't1', 's2']) {
        await assertFails(getDoc(doc(as(uid), path)));
        await assertFails(setDoc(doc(as(uid), path), { x: 1 }));
        await assertFails(gatewayWrite(as(uid), path, { x: 1 }));
      }
    }
  });
});

describe('shared photos (what the trainer can see of a student\u2019s cards)', () => {
  const path = (id = 'photo-1') => `students/s1/sharedPhotos/${id}`;
  const seed = () => env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), path()), sharedPhoto({}, 1, { raw: true })));

  it('the student and their linked trainer can read; another student, an unlinked trainer and a revoked link cannot', async () => {
    await seed();
    await assertSucceeds(getDoc(doc(as('s1'), path())));
    await assertSucceeds(getDoc(doc(as('t1'), path())));
    await assertFails(getDoc(doc(as('s2'), path())));
    await assertFails(getDoc(doc(as('t2'), path())));
  });
  it('the trainer can list a linked student\u2019s photos', async () => {
    await seed();
    const snap = await assertSucceeds(getDocs(collection(as('t1'), 'students/s1/sharedPhotos')));
    assert(snap.size === 1);
    await assertFails(getDocs(collection(as('t2'), 'students/s1/sharedPhotos')));
  });
  it('only the student writes them — never the trainer, a stranger, or someone using another student\u2019s id', async () => {
    await assertSucceeds(gatewayWrite(as('s1'), path('photo-new'), sharedPhoto({ id: 'photo-new' })));
    await assertFails(gatewayWrite(as('t1'), path('photo-new'), sharedPhoto({ id: 'photo-new' })));
    await assertFails(gatewayWrite(as('s2'), path('photo-new'), sharedPhoto({ id: 'photo-new' })));
    await assertFails(gatewayWrite(as('s1'), path('photo-new'), sharedPhoto({ id: 'photo-new', studentID: 's2' })));
    await assertFails(gatewayWrite(as('s1'), path('photo-new'), sharedPhoto({ id: 'other-id' })));
  });
  it('are validated for shape and size, and are never hard-deleted', async () => {
    const db = as('s1');
    for (const bad of [{ photo: 42 }, { photo: 'x'.repeat(700001) }, { caption: 'c'.repeat(161) }, { caption: 7 }]) {
      await assertFails(gatewayWrite(db, path('photo-new'), sharedPhoto({ id: 'photo-new', ...bad })));
    }
    await assertSucceeds(gatewayWrite(db, path('photo-new'), sharedPhoto({ id: 'photo-new', photo: 'x'.repeat(700000) })));
    await assertFails(gatewayWrite(db, path('photo-stamp'), sharedPhoto({ id: 'photo-stamp' }), { stamped: false }));
    await seed();
    await assertFails(deleteDoc(doc(db, path())));
  });
  it('removal is a tombstone written by the student with an advancing version; the trainer cannot edit or restore it', async () => {
    await seed();
    const tomb = sharedPhoto({ photo: '', meta: { ...meta(2), deletedAt: now() } }, 2);
    await assertFails(gatewayWrite(as('t1'), path(), tomb));
    await assertSucceeds(gatewayWrite(as('s1'), path(), tomb));
    await assertFails(gatewayWrite(as('s1'), path(), sharedPhoto({}, 1)));            // the version has to advance
  });
  it('the card itself stays private: the trainer still cannot read posts', async () => {
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), 'students/s1/posts/p1'), { id: 'p1', studentID: 's1', kind: 'workout', title: 'x', _rev: 1, _mutationId: 'seed', _updatedAt: Timestamp.now(), meta: meta(1) }));
    await assertSucceeds(getDoc(doc(as('s1'), 'students/s1/posts/p1')));
    await assertFails(getDoc(doc(as('t1'), 'students/s1/posts/p1')));
  });
});

describe('trainer profile (what students see of their trainer)', () => {
  const path = (id = 't1') => `trainerProfiles/${id}`;
  const seed = () => env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), path()), trainerProfile({}, 1, { raw: true })));

  it('the trainer and their linked student can read it; another student, another trainer and a revoked link cannot', async () => {
    await seed();
    await assertSucceeds(getDoc(doc(as('t1'), path())));
    await assertSucceeds(getDoc(doc(as('s1'), path())));
    await assertFails(getDoc(doc(as('s2'), path())));          // never linked to t1
    await assertFails(getDoc(doc(as('s3'), path())));          // link revoked
    await assertFails(getDoc(doc(as('t2'), path())));
  });
  it('the student\u2019s app can listen to exactly their trainer\u2019s document, and cannot list the collection', async () => {
    await seed();
    const own = query(collection(as('s1'), 'trainerProfiles'), where(documentId(), '==', 't1'));
    assert((await assertSucceeds(getDocs(own))).size === 1);
    await assertFails(getDocs(query(collection(as('s2'), 'trainerProfiles'), where(documentId(), '==', 't1'))));
    await assertFails(getDocs(collection(as('s1'), 'trainerProfiles')));
  });
  it('only the trainer writes it, through the gateway, as themselves', async () => {
    await assertSucceeds(gatewayWrite(as('t1'), path(), trainerProfile()));
    await assertFails(gatewayWrite(as('s1'), path(), trainerProfile()));                   // a student can't write their trainer's profile
    await assertFails(gatewayWrite(as('t2'), path(), trainerProfile()));                   // nor another trainer
    await assertFails(gatewayWrite(as('s1'), path('s1'), trainerProfile({ id: 's1' })));   // nor make one for themselves: not a trainer account
    await assertFails(gatewayWrite(as('t1'), path(), trainerProfile({ id: 't2' })));
    await assertFails(gatewayWrite(as('t1'), path(), trainerProfile(), { stamped: false }));
  });
  it('validates the name, the CREF format and the photo size; the CREF and photo are optional', async () => {
    const db = as('t1');
    for (const bad of [{ displayName: '' }, { displayName: 'x'.repeat(121) }, { displayName: 7 }, { cref: '12345-G/AL' }, { cref: '012345-X/AL' },
      { cref: '012345-G/al' }, { cref: 'CREF 012345-G/AL' }, { cref: 123456 }, { photo: 'x'.repeat(400001) }, { photo: 42 }]) {
      await assertFails(gatewayWrite(db, path(), trainerProfile(bad)));
    }
    await assertSucceeds(gatewayWrite(db, path(), { id: 't1', displayName: 'Only a name', meta: meta(1) }));
    await assertSucceeds(gatewayWrite(db, path(), trainerProfile({ cref: null, photo: null }, 2)));
    await assertSucceeds(gatewayWrite(db, path(), trainerProfile({ photo: 'x'.repeat(400000) }, 3)));
  });
  it('edits need an advancing version, and it is never deleted', async () => {
    await seed();
    await assertSucceeds(gatewayWrite(as('t1'), path(), trainerProfile({ displayName: 'Renamed' }, 2)));
    await assertFails(gatewayWrite(as('t1'), path(), trainerProfile({ displayName: 'Again' }, 2)));
    await assertFails(deleteDoc(doc(as('t1'), path())));
  });
});

describe('coached logs (workouts the trainer ran next to the student)', () => {
  const path = (id = 'c-new') => `students/s1/coachedLogs/${id}`;
  const seed = () => env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), path('c1')), coachedLog({ id: 'c1', planID: 'p1' }, 1, { raw: true })));

  it('the linked trainer creates one for a plan of theirs; the student and the trainer both read it', async () => {
    await assertSucceeds(gatewayWrite(as('t1'), path(), coachedLog({ planID: 'p1' })));
    await seed();
    await assertSucceeds(getDoc(doc(as('s1'), path('c1'))));
    await assertSucceeds(getDoc(doc(as('t1'), path('c1'))));
    await assertFails(getDoc(doc(as('s2'), path('c1'))));
    await assertFails(getDoc(doc(as('t2'), path('c1'))));
  });
  it('the student cannot write one — not even by naming their trainer as coachedBy', async () => {
    await assertFails(gatewayWrite(as('s1'), path(), coachedLog({ planID: 'p1' })));
    await assertFails(gatewayWrite(as('s1'), path(), coachedLog({ planID: 'p1', coachedBy: 's1' })));
    await seed();
    await assertFails(gatewayWrite(as('s1'), path('c1'), coachedLog({ id: 'c1', planID: 'p1', status: 'completed' }, 2)));
  });
  it('an unlinked trainer, a revoked link, another trainer\u2019s plan and a forged coachedBy are all refused', async () => {
    await assertFails(gatewayWrite(as('t2'), path(), coachedLog({ planID: 'p1', coachedBy: 't2' })));      // not linked
    await assertFails(gatewayWrite(as('t1'), path(), coachedLog({ planID: 'p1', coachedBy: 't2' })));      // claims to be someone else
    await assertFails(gatewayWrite(as('t1'), path(), coachedLog({ planID: 'p1', studentID: 's2' })));      // another student's id in s1's collection
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), 'plans/p-other'), plan({ id: 'p-other', trainerID: 't2' }, 1, { raw: true })));
    await assertFails(gatewayWrite(as('t1'), path(), coachedLog({ planID: 'p-other' })));                   // a plan that belongs to t2
    await assertFails(gatewayWrite(as('t1'), 'students/s3/coachedLogs/c-new', coachedLog({ planID: 'p1', studentID: 's3' })));   // revoked link
  });
  it('is validated like any log: status, size, effort', async () => {
    const db = as('t1');
    for (const bad of [{ status: 'done' }, { sessionRPE: 11 }, { sessionRPE: 0 }, { blocks: Array(41).fill({}) }, { feedbackNote: 'x'.repeat(2001) }]) {
      await assertFails(gatewayWrite(db, path(), coachedLog({ planID: 'p1', ...bad })));
    }
    await assertSucceeds(gatewayWrite(db, path(), coachedLog({ planID: 'p1', status: 'completed', sessionRPE: 8 })));
    await assertFails(gatewayWrite(db, path('c-stamp'), coachedLog({ id: 'c-stamp', planID: 'p1' }), { stamped: false }));
  });
  it('is edited only by the trainer who ran it, with an advancing version, never reassigned or deleted', async () => {
    await seed();
    await assertSucceeds(gatewayWrite(as('t1'), path('c1'), coachedLog({ id: 'c1', planID: 'p1', status: 'completed', sessionRPE: 7 }, 2)));
    await assertFails(gatewayWrite(as('t1'), path('c1'), coachedLog({ id: 'c1', planID: 'p1', sessionRPE: 6 }, 2)));            // version didn't advance
    await assertFails(gatewayWrite(as('t1'), path('c1'), coachedLog({ id: 'c1', planID: 'p1', coachedBy: 't2' }, 3)));         // reassigned
    await assertFails(gatewayWrite(as('t1'), path('c1'), coachedLog({ id: 'c1', planID: 'p-other' }, 4)));                     // moved to another plan
    await assertFails(gatewayWrite(as('t2'), path('c1'), coachedLog({ id: 'c1', planID: 'p1', coachedBy: 't2' }, 5)));
    await assertFails(deleteDoc(doc(as('t1'), path('c1'))));
  });
  it('a student\u2019s own workouts can no longer claim to be coached', async () => {
    await assertSucceeds(gatewayWrite(as('s1'), 'students/s1/workoutLogs/l-own', log({ id: 'l-own', planID: 'p1' })));
    await assertFails(gatewayWrite(as('s1'), 'students/s1/workoutLogs/l-fake', log({ id: 'l-fake', planID: 'p1', coachedBy: 't1' })));
    await assertSucceeds(gatewayWrite(as('s1'), 'students/s1/workoutLogs/l-null', log({ id: 'l-null', planID: 'p1', coachedBy: null })));
  });
});

describe('exercise cache', () => {
  it('is readable by signed-in users and never writable from a client', async () => {
    await assertSucceeds(getDoc(doc(as('s1'), 'exerciseCache/squat')));
    await assertFails(getDoc(doc(anonymous(), 'exerciseCache/squat')));
    await assertFails(setDoc(doc(as('t1'), 'exerciseCache/squat'), { name: 'Hacked' }));
  });
});

describe('posts', () => {
  const path = (id) => `students/s1/posts/${id}`;
  it('are created and edited by the student, who is the only reader (not even the linked trainer)', async () => {
    await assertSucceeds(gatewayWrite(as('s1'), path('post-new'), post()));
    await assertSucceeds(getDoc(doc(as('s1'), path('post-1'))));
    await assertSucceeds(gatewayWrite(as('s1'), path('post-1'), post({ id: 'post-1', title: 'Renamed' }, 2)));
    await assertFails(getDoc(doc(as('t1'), path('post-1'))));
    await assertFails(getDoc(doc(as('s2'), path('post-1'))));
  });
  it('cannot be written by anyone else or forged for another student', async () => {
    await assertFails(gatewayWrite(as('s2'), path('post-new'), post()));
    await assertFails(gatewayWrite(as('t1'), path('post-new'), post()));
    await assertFails(gatewayWrite(as('s1'), path('post-new'), post({ studentID: 's2' })));
  });
  it('are validated: id matches the path, known kind, bounded sizes, advancing version, no deletes', async () => {
    const db = as('s1');
    await assertFails(gatewayWrite(db, path('post-new'), post({ id: 'other' })));
    await assertFails(gatewayWrite(db, path('post-new'), post({ kind: 'advert' })));
    await assertFails(gatewayWrite(db, path('post-new'), post({ title: '' })));
    await assertFails(gatewayWrite(db, path('post-new'), post({ title: 'x'.repeat(161) })));
    await assertFails(gatewayWrite(db, path('post-new'), post({ tracks: Array.from({ length: 11 }, () => ({ title: 't', artist: 'a', plays: 1 })) })));
    await assertFails(gatewayWrite(db, path('post-new'), post({ photo: 'A'.repeat(700001) })));   // a photo must stay small
    await assertFails(gatewayWrite(db, path('post-new'), post({ photo: 12345 })));
    await assertSucceeds(gatewayWrite(db, path('post-ph'), post({ id: 'post-ph', photo: 'A'.repeat(1000) })));
    await assertFails(gatewayWrite(db, path('post-1'), post({ id: 'post-1' }, 1)));          // version must advance
    await assertFails(deleteDoc(doc(db, path('post-1'))));
  });
});

describe('Strava activities & integration links (server-written)', () => {
  const path = (id) => `students/s1/externalActivities/${id}`;
  it('the student reads their own; no client — student, trainer or stranger — can ever write them', async () => {
    await assertSucceeds(getDoc(doc(as('s1'), path('strava-1'))));
    await assertFails(getDoc(doc(as('s2'), path('strava-1'))));
    for (const uid of ['s1', 's2', 't1']) {
      await assertFails(gatewayWrite(as(uid), path('strava-new'), activity()));
      await assertFails(deleteDoc(doc(as(uid), path('strava-1'))));
    }
  });
  it('a linked trainer is denied by default (student has not shared, switch not set)', async () => {
    await assertFails(getDoc(doc(as('t1'), path('strava-1'))));
    await assertFails(getDocs(collection(as('t1'), 'students/s1/externalActivities')));
  });
  it('a linked trainer can read only when the student shares AND the operator switch is on', async () => {
    await configure({ killSwitchOn: true, studentShares: true });
    await assertSucceeds(getDoc(doc(as('t1'), path('strava-1'))));
    await assertSucceeds(getDocs(collection(as('t1'), 'students/s1/externalActivities')));

    await configure({ killSwitchOn: false });                       // operator turns coach visibility off for everyone
    await assertFails(getDoc(doc(as('t1'), path('strava-1'))));
    await assertSucceeds(getDoc(doc(as('s1'), path('strava-1'))));  // the student still sees their own

    await configure({ killSwitchOn: true, studentShares: false });  // or the student withdraws consent
    await assertFails(getDoc(doc(as('t1'), path('strava-1'))));
  });
  it('sharing alone is not enough: a missing operator switch fails closed', async () => {
    await configure({ studentShares: true });
    await assertFails(getDoc(doc(as('t1'), path('strava-1'))));
  });
  it('an unlinked trainer never reads them, even when everything is switched on', async () => {
    await configure({ killSwitchOn: true, studentShares: true });
    await assertFails(getDoc(doc(as('t2'), path('strava-1'))));
  });
  it('integration links: readable by the student only, writable by nobody on the client', async () => {
    await assertSucceeds(getDoc(doc(as('s1'), 'students/s1/integrations/strava')));
    await assertFails(getDoc(doc(as('t1'), 'students/s1/integrations/strava')));
    // The attack this blocks: claiming somebody else's Strava athlete id to receive their webhook events.
    await assertFails(gatewayWrite(as('s1'), 'students/s1/integrations/strava', { id: 'strava', provider: 'strava', studentID: 's1', isConnected: true, externalAccountID: '999', meta: meta(2) }));
    await assertFails(gatewayWrite(as('s2'), 'students/s2/integrations/strava', { id: 'strava', provider: 'strava', studentID: 's2', isConnected: true, externalAccountID: '777', meta: meta(1) }));
  });
  it('server-only collections (tokens, queued events, rate limits, OAuth states) are invisible to clients', async () => {
    for (const path of ['stravaTokens/s1', 'stravaEvents/e1', 'rateLimits/places-s1', 'stravaStates/abc']) {
      await assertFails(getDoc(doc(as('s1'), path)));
      await assertFails(getDoc(doc(as('t1'), path)));
      await assertFails(setDoc(doc(as('s1'), path), { x: 1 }));
    }
  });
});

describe('sharing preferences', () => {
  const path = 'students/s1/sharing/preferences';
  it('the student reads and writes their own switches, through the gateway', async () => {
    await assertSucceeds(gatewayWrite(as('s1'), path, prefs({ shareStravaWithTrainer: true })));
    await assertSucceeds(getDoc(doc(as('s1'), path)));
    await assertSucceeds(gatewayWrite(as('s1'), path, prefs({ shareStravaWithTrainer: false }, 2)));
  });
  it('nobody else can read or write them — the trainer cannot flip the student’s consent', async () => {
    await assertFails(gatewayWrite(as('t1'), path, prefs({ shareStravaWithTrainer: true })));
    await assertFails(gatewayWrite(as('s2'), path, prefs()));
    await assertFails(getDoc(doc(as('t1'), path)));
  });
  it('rejects wrong shapes, another student’s id, other document names and deletes', async () => {
    const db = as('s1');
    await assertFails(gatewayWrite(db, path, prefs({ shareStravaWithTrainer: 'yes' })));
    await assertFails(gatewayWrite(db, path, prefs({ includeMusicInPosts: 1 })));
    await assertFails(gatewayWrite(db, path, prefs({ studentID: 's2' })));
    await assertFails(gatewayWrite(db, 'students/s1/sharing/other', prefs()));
    await assertFails(gatewayWrite(db, path, prefs(), { stamped: false }));
    await assertSucceeds(gatewayWrite(db, path, prefs()));
    await assertFails(deleteDoc(doc(db, path)));
  });
});

describe('config (operator switches)', () => {
  it('readable by signed-in users, never writable from a client', async () => {
    await configure({ killSwitchOn: true });
    await assertSucceeds(getDoc(doc(as('s1'), 'config/features')));
    await assertFails(getDoc(doc(anonymous(), 'config/features')));
    await assertFails(setDoc(doc(as('t1'), 'config/features'), { stravaCoachSharing: true }));
  });
});

describe('registrations (the trainer’s students)', () => {
  it('only the trainer who registered the student can read the record', async () => {
    await assertSucceeds(getDoc(doc(as('t1'), 'registrations/reg-1')));
    await assertSucceeds(getDocs(query(collection(as('t1'), 'registrations'), where('trainerID', '==', 't1'))));
    await assertFails(getDoc(doc(as('t2'), 'registrations/reg-1')));            // another trainer
    await assertFails(getDoc(doc(as('s1'), 'registrations/reg-1')));            // the student herself
    await assertFails(getDoc(doc(anonymous(), 'registrations/reg-1')));
    await assertFails(getDocs(collection(as('s1'), 'registrations')));
  });
  it('is written only by Cloud Functions: no client can create, edit or delete one', async () => {
    for (const uid of ['t1', 't2', 's1']) {
      await assertFails(setDoc(doc(as(uid), 'registrations/new'), { id: 'new', trainerID: uid, fullName: 'A B', status: 'invited' }));
      await assertFails(setDoc(doc(as(uid), 'registrations/reg-1'), { id: 'reg-1', trainerID: uid, fullName: 'Hijacked Name', status: 'invited' }));
      await assertFails(deleteDoc(doc(as(uid), 'registrations/reg-1')));
    }
  });
  it('first-access claim tokens are invisible to every client', async () => {
    for (const uid of ['t1', 's1']) {
      await assertFails(getDoc(doc(as(uid), 'claimTokens/abc')));
      await assertFails(setDoc(doc(as(uid), 'claimTokens/abc'), { registrationId: 'reg-1' }));
    }
    await assertFails(getDoc(doc(anonymous(), 'claimTokens/abc')));
  });
});

describe('trainer nicknames (private to the personal)', () => {
  const path = 'trainers/t1/nicknames/reg-1';
  const nick = (over = {}, version = 1) => ({ id: 'reg-1', trainerID: 't1', nickname: 'Tigresa 7h', meta: meta(version), ...over });
  it('the trainer reads and writes their own, through the gateway', async () => {
    await assertSucceeds(getDoc(doc(as('t1'), path)));
    await assertSucceeds(gatewayWrite(as('t1'), path, nick({ nickname: 'Tigresa da manhã' }, 2)));
    await assertSucceeds(gatewayWrite(as('t1'), 'trainers/t1/nicknames/reg-2', nick({ id: 'reg-2' })));
  });
  it('NO student account can ever read it — the nickname never reaches the student', async () => {
    await assertFails(getDoc(doc(as('s1'), path)));                             // the very student it is about
    await assertFails(getDoc(doc(as('s2'), path)));
    await assertFails(getDocs(collection(as('s1'), 'trainers/t1/nicknames')));
    await assertFails(getDoc(doc(anonymous(), path)));
  });
  it('another trainer can neither read nor write it, nor plant one in this namespace', async () => {
    await assertFails(getDoc(doc(as('t2'), path)));
    await assertFails(gatewayWrite(as('t2'), path, nick({}, 2)));
    await assertFails(gatewayWrite(as('t2'), 'trainers/t1/nicknames/reg-9', nick({ id: 'reg-9' })));
    await assertFails(gatewayWrite(as('s1'), 'trainers/t1/nicknames/reg-9', nick({ id: 'reg-9' })));
  });
  it('is validated: right owner and id, 1–30 characters, a string, advancing versions, no hard deletes', async () => {
    const db = as('t1');
    await assertFails(gatewayWrite(db, 'trainers/t1/nicknames/reg-3', nick({ id: 'reg-3', trainerID: 't2' })));
    await assertFails(gatewayWrite(db, 'trainers/t1/nicknames/reg-3', nick({ id: 'other' })));
    await assertFails(gatewayWrite(db, 'trainers/t1/nicknames/reg-3', nick({ id: 'reg-3', nickname: '' })));
    await assertFails(gatewayWrite(db, 'trainers/t1/nicknames/reg-3', nick({ id: 'reg-3', nickname: 'x'.repeat(31) })));
    await assertFails(gatewayWrite(db, 'trainers/t1/nicknames/reg-3', nick({ id: 'reg-3', nickname: 42 })));
    await assertFails(gatewayWrite(db, path, nick({}, 1)));                     // version must advance
    await assertSucceeds(gatewayWrite(db, 'trainers/t1/nicknames/edge', nick({ id: 'edge', nickname: 'x'.repeat(30) })));
    await assertFails(deleteDoc(doc(db, path)));
  });
});

function assert(condition) { if (!condition) throw new Error('assertion failed'); }
