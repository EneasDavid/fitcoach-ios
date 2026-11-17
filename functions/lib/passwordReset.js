'use strict';
// Password reset for students — pure logic (no Firebase, no network), so every rule is unit-tested.
//
// Flow
//   student ─ requestPasswordReset {cpf, email} ─► ALWAYS "ok". Only when the CPF belongs to an active registration whose registered
//             e-mail equals the one typed does a 6-digit code get e-mailed (to the REGISTERED address, never to what was typed).
//   student ─ confirmPasswordReset {cpf, code, password} ─► password changed, every session revoked.
//
// Why a code and not Firebase's own reset link: accounts are created under an opaque login alias (`…@students.fitcoach.invalid`), so
// Firebase has no deliverable address for them. The real e-mail lives on the registration; we send the code there ourselves.
// The code is stored only as an HMAC (keyed with a server secret, bound to the registration), expires, and locks after a few misses.

const crypto = require('node:crypto');

const RESET_TTL_MS = 15 * 60 * 1000;
const MAX_CODE_ATTEMPTS = 5;
const RESEND_COOLDOWN_MS = 60 * 1000;

const normalizeEmail = (value) => (typeof value === 'string' ? value.trim().toLowerCase() : '');
const validEmailShape = (email) => email.length > 0 && email.length <= 254 && /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email);

/** Constant-time string comparison (compares fixed-length digests, so lengths never leak). */
function safeEqual(a, b) {
  const digest = (value) => crypto.createHash('sha256').update(String(value)).digest();
  return crypto.timingSafeEqual(digest(a), digest(b));
}

/** The e-mail must match the one on an ACTIVE registration. Anything else is a quiet "no". */
function decideRequest(registration, typedEmail) {
  if (!registration || registration.status !== 'active' || typeof registration.studentID !== 'string') return { ok: false };
  const stored = normalizeEmail(registration.email);
  const given = normalizeEmail(typedEmail);
  if (!validEmailShape(stored) || !validEmailShape(given)) return { ok: false };
  return safeEqual(stored, given) ? { ok: true, to: stored } : { ok: false };
}

/** One request per registration per minute (a second tap must not fire a second e-mail). */
function canRequest(existing, nowMs) {
  return !(existing && typeof existing.requestedAt === 'number' && existing.requestedAt + RESEND_COOLDOWN_MS > nowMs);
}

function newResetCode(randomInt = crypto.randomInt) {
  return String(randomInt(0, 1_000_000)).padStart(6, '0');
}

const codeHash = (secret, registrationId, code) =>
  crypto.createHmac('sha256', secret).update(`reset|${registrationId}|${code}`).digest('hex');

function newResetRecord(secret, registrationId, code, nowMs) {
  return { registrationId, codeHash: codeHash(secret, registrationId, code), expiresAt: nowMs + RESET_TTL_MS, attempts: 0, requestedAt: nowMs };
}

/** Decides one confirmation attempt. `wrong` is the only outcome that should cost an attempt. */
function checkCode(record, secret, registrationId, typedCode, nowMs) {
  if (!record || record.registrationId !== registrationId || typeof record.codeHash !== 'string') return { ok: false, reason: 'unknown' };
  if (!(record.expiresAt > nowMs)) return { ok: false, reason: 'expired' };
  if (!(record.attempts < MAX_CODE_ATTEMPTS)) return { ok: false, reason: 'locked' };
  const code = String(typedCode ?? '').replace(/\s/g, '');
  if (!/^\d{6}$/.test(code)) return { ok: false, reason: 'wrong' };
  return safeEqual(record.codeHash, codeHash(secret, registrationId, code)) ? { ok: true } : { ok: false, reason: 'wrong' };
}

const validateNewPassword = (value) => typeof value === 'string' && value.length >= 8 && value.length <= 128;

/** The e-mail (Portuguese, like the app). Plain text only: nothing in it can be turned into a link or a script. */
function resetMessage({ name, code }) {
  const first = String(name ?? '').replace(/[\u0000-\u001f]/g, '').trim().split(/\s+/)[0] || '';
  const minutes = RESET_TTL_MS / 60000;
  return {
    subject: 'FitCoach: seu código para redefinir a senha',
    text: [
      first ? `Olá, ${first}.` : 'Olá.',
      '',
      `Seu código para redefinir a senha do FitCoach é: ${code}`,
      `Ele vale por ${minutes} minutos e só pode ser usado uma vez.`,
      '',
      'Se não foi você quem pediu, ignore esta mensagem: sua senha continua a mesma.',
    ].join('\n'),
  };
}

module.exports = {
  RESET_TTL_MS, MAX_CODE_ATTEMPTS, RESEND_COOLDOWN_MS,
  normalizeEmail, validEmailShape, decideRequest, canRequest, newResetCode, codeHash, newResetRecord, checkCode, validateNewPassword, resetMessage,
};
