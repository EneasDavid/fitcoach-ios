'use strict';
// Student registration, first access and login aliases — pure logic (no Firebase, no network), so every rule is unit-tested.
//
// Flow
//   trainer  ─ registerStudent {cpf, fullName} ─►  registrations/{key}   key = HMAC(secret, cpf)  (never the CPF itself)
//   student  ─ claimRegistration {cpf, fullName} ─► one-time token       (same "not found" for unknown CPF and wrong name)
//   student  ─ completeRegistration {token, email, age, gender, heightCm, weightKg, password} ─► account created, trainerLink activated, custom token
//   login    ─ loginAlias {identifier} ─► opaque login name (HMAC, computed for ANY input: no lookup, so nothing to enumerate)
//
// A CPF has ~10^9 values, so an unkeyed hash of it can be brute-forced. Everything here uses an HMAC whose secret never leaves the server.

const crypto = require('node:crypto');

const TOKEN_TTL_MS = 15 * 60 * 1000;
const GENDERS = new Set(['female', 'male', 'other', 'preferNotToSay']);

/** 11 digits with valid check digits, or null. */
function normalizeCpf(input) {
  if (typeof input !== 'string' || !/^[\d.\-\s]+$/.test(input)) return null;
  const digits = input.replace(/\D/g, '');
  if (digits.length !== 11 || new Set(digits).size === 1) return null;
  const d = [...digits].map(Number);
  const check = (count) => {
    let sum = 0;
    for (let i = 0; i < count; i += 1) sum += d[i] * (count + 1 - i);
    return ((sum * 10) % 11) % 10;
  };
  return check(9) === d[9] && check(10) === d[10] ? digits : null;
}

const CREF_UNITS = new Set(['AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG', 'PA', 'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO']);

/** "012345-G/AL" style registration, normalised; or null. */
function normalizeCref(input) {
  if (typeof input !== 'string') return null;
  let body = input.toUpperCase().trim();
  if (body.startsWith('CREF')) body = body.slice(4).trim();
  const slash = body.lastIndexOf('/');
  if (slash < 0) return null;
  const unit = body.slice(slash + 1).trim();
  if (!CREF_UNITS.has(unit)) return null;
  const head = body.slice(0, slash).trim();
  const category = head.slice(-1);
  if (category !== 'G' && category !== 'P') return null;
  const number = head.slice(0, -1).replace(/[-\s]+$/g, '');
  if (!/^\d{4,6}$/.test(number)) return null;
  return `${number.padStart(6, '0')}-${category}/${unit}`;
}

/** Two or more words, letters (plus ' - ’) only, ≤ 120 chars; whitespace collapsed. */
function normalizeName(input) {
  if (typeof input !== 'string') return null;
  const collapsed = input.split(/\s+/).filter(Boolean).join(' ');
  if (collapsed.length > 120 || collapsed.split(' ').length < 2) return null;
  return /^[\p{L}' \-’]+$/u.test(collapsed) ? collapsed : null;
}

/** Case, accents and spacing are ignored when the student repeats the name the trainer typed. */
function foldName(name) {
  return String(name).normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().split(/\s+/).filter(Boolean).join(' ');
}
const namesMatch = (a, b) => foldName(a) === foldName(b);

function maskCpf(digits) {
  return digits.length === 11 ? `***.${digits.slice(3, 6)}.${digits.slice(6, 9)}-**` : '***';
}

const hmac = (secret, purpose, value) => crypto.createHmac('sha256', secret).update(`${purpose}|${value}`).digest('hex');

/** Opaque registration id for a CPF. */
const registrationKey = (secret, cpfDigits) => hmac(secret, 'registration', cpfDigits);

/** Opaque login name for a CPF/CREF. Computed for ANY input — it never looks anything up. */
const loginAlias = (secret, identifier) => `${hmac(secret, 'login', identifier).slice(0, 40)}@students.fitcoach.invalid`;

const round1 = (n) => Math.round(n * 10) / 10;

/** Validates the profile the student sends in step 2. Returns { ok, profile } or { ok: false, reason }. */
function validateProfile(body) {
  if (!body || typeof body !== 'object') return { ok: false, reason: 'body' };
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  if (email.length > 254 || !/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email)) return { ok: false, reason: 'email' };
  if (!Number.isInteger(body.age) || body.age < 12 || body.age > 100) return { ok: false, reason: 'age' };
  if (!GENDERS.has(body.gender)) return { ok: false, reason: 'gender' };
  if (!Number.isFinite(body.heightCm) || body.heightCm < 100 || body.heightCm > 250) return { ok: false, reason: 'height' };
  if (!Number.isFinite(body.weightKg) || body.weightKg < 20 || body.weightKg > 400) return { ok: false, reason: 'weight' };
  if (typeof body.password !== 'string' || body.password.length < 8 || body.password.length > 128) return { ok: false, reason: 'password' };
  return { ok: true, profile: { email, age: body.age, gender: body.gender, heightCm: round1(body.heightCm), weightKg: round1(body.weightKg) }, password: body.password };
}

/**
 * Step 1 decision. `registration` is the stored document for the CPF's key (or undefined).
 * Unknown CPF and wrong name are the very same outcome on purpose.
 */
function decideClaim(registration, fullName) {
  if (!registration || !namesMatch(registration.fullName, fullName)) return { ok: false, status: 404, error: 'not-found' };
  if (registration.status !== 'invited') return { ok: false, status: 409, error: 'already-claimed' };
  return { ok: true };
}

/** One-time claim token: random, bound to a registration, expiring. Only its hash is stored. */
function newToken(registrationId, nowMs, randomBytes = crypto.randomBytes) {
  const token = randomBytes(32).toString('hex');
  return { token, record: { tokenHash: crypto.createHash('sha256').update(token).digest('hex'), registrationId, expiresAt: nowMs + TOKEN_TTL_MS } };
}

const tokenHash = (token) => crypto.createHash('sha256').update(String(token)).digest('hex');

function validateToken(record, nowMs) {
  if (!record || typeof record.registrationId !== 'string') return { ok: false, reason: 'unknown-token' };
  if (!(record.expiresAt > nowMs)) return { ok: false, reason: 'expired' };
  return { ok: true, registrationId: record.registrationId };
}

/** Per-IP/CPF fixed-window attempts limit for the unauthenticated endpoints. */
function consumeAttempt(counter, nowMs, { limit, windowMs }) {
  const fresh = !counter || !(counter.windowStart + windowMs > nowMs);
  const state = fresh ? { windowStart: nowMs, count: 0 } : { windowStart: counter.windowStart, count: counter.count };
  if (state.count >= limit) return { allowed: false, next: state, retryAfterSeconds: Math.max(1, Math.ceil((state.windowStart + windowMs - nowMs) / 1000)) };
  return { allowed: true, next: { windowStart: state.windowStart, count: state.count + 1 } };
}

module.exports = {
  TOKEN_TTL_MS, normalizeCpf, normalizeCref, normalizeName, foldName, namesMatch, maskCpf, registrationKey, loginAlias,
  validateProfile, decideClaim, newToken, tokenHash, validateToken, consumeAttempt,
};
