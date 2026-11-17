'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const pr = require('../lib/passwordReset');

const SECRET = 'test-secret';
const active = { status: 'active', studentID: 'stu-1', email: 'ana@example.com', fullName: 'Ana Lima' };

test('request: only an ACTIVE registration with the same e-mail (case and spaces ignored) gets a code, and it goes to the stored address', () => {
  assert.deepEqual(pr.decideRequest(active, ' Ana@Example.COM '), { ok: true, to: 'ana@example.com' });
  for (const [registration, email] of [
    [undefined, 'ana@example.com'],                              // unknown CPF
    [active, 'other@example.com'],                               // wrong e-mail
    [{ ...active, status: 'invited' }, 'ana@example.com'],       // never finished first access
    [{ ...active, email: undefined }, 'ana@example.com'],        // nothing on file
    [{ ...active, studentID: undefined }, 'ana@example.com'],
    [active, 'not-an-email'], [active, ''], [active, null],
  ]) {
    assert.deepEqual(pr.decideRequest(registration, email), { ok: false });
  }
});

test('request: a second tap inside the cooldown does not send a second e-mail', () => {
  assert.equal(pr.canRequest(undefined, 1000), true);
  assert.equal(pr.canRequest({ requestedAt: 1000 }, 1000 + pr.RESEND_COOLDOWN_MS - 1), false);
  assert.equal(pr.canRequest({ requestedAt: 1000 }, 1000 + pr.RESEND_COOLDOWN_MS), true);
});

test('codes: six digits, zero-padded, from the injected source', () => {
  assert.equal(pr.newResetCode(() => 7), '000007');
  assert.equal(pr.newResetCode(() => 999999), '999999');
  assert.match(pr.newResetCode(), /^\d{6}$/);
});

test('record: only a keyed hash bound to the registration is stored — never the code', () => {
  const record = pr.newResetRecord(SECRET, 'reg-1', '123456', 5000);
  assert.deepEqual(Object.keys(record).sort(), ['attempts', 'codeHash', 'expiresAt', 'registrationId', 'requestedAt']);
  assert.ok(!JSON.stringify(record).includes('123456'));
  assert.equal(record.expiresAt, 5000 + pr.RESET_TTL_MS);
  assert.notEqual(pr.codeHash(SECRET, 'reg-1', '123456'), pr.codeHash(SECRET, 'reg-2', '123456'));      // bound to the registration
  assert.notEqual(pr.codeHash(SECRET, 'reg-1', '123456'), pr.codeHash('other-secret', 'reg-1', '123456'));
});

test('confirm: right code passes; wrong, malformed, expired, locked and foreign records fail for the right reason', () => {
  const record = pr.newResetRecord(SECRET, 'reg-1', '123456', 0);
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', '123456', 1000), { ok: true });
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', '123 456', 1000), { ok: true });           // spaces typed by the user
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', '654321', 1000), { ok: false, reason: 'wrong' });
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', '12345', 1000), { ok: false, reason: 'wrong' });
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', 'abcdef', 1000), { ok: false, reason: 'wrong' });
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', undefined, 1000), { ok: false, reason: 'wrong' });
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', '123456', pr.RESET_TTL_MS), { ok: false, reason: 'expired' });
  assert.deepEqual(pr.checkCode({ ...record, attempts: pr.MAX_CODE_ATTEMPTS }, SECRET, 'reg-1', '123456', 1000), { ok: false, reason: 'locked' });
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-2', '123456', 1000), { ok: false, reason: 'unknown' });     // another registration's code
  assert.deepEqual(pr.checkCode(undefined, SECRET, 'reg-1', '123456', 1000), { ok: false, reason: 'unknown' });
  assert.deepEqual(pr.checkCode(record, 'other-secret', 'reg-1', '123456', 1000), { ok: false, reason: 'wrong' });
});

test('a locked record refuses even the right code', () => {
  let record = pr.newResetRecord(SECRET, 'reg-1', '123456', 0);
  for (let i = 0; i < pr.MAX_CODE_ATTEMPTS; i += 1) {
    assert.equal(pr.checkCode(record, SECRET, 'reg-1', '000000', 10).reason, 'wrong');
    record = { ...record, attempts: record.attempts + 1 };
  }
  assert.deepEqual(pr.checkCode(record, SECRET, 'reg-1', '123456', 10), { ok: false, reason: 'locked' });
});

test('new password: 8–128 characters', () => {
  assert.equal(pr.validateNewPassword('12345678'), true);
  assert.equal(pr.validateNewPassword('x'.repeat(128)), true);
  for (const bad of ['1234567', 'x'.repeat(129), '', null, undefined, 12345678]) assert.equal(pr.validateNewPassword(bad), false);
});

test('message: Portuguese, plain text, greets by first name, carries the code and the expiry, and tolerates odd names', () => {
  const { subject, text } = pr.resetMessage({ name: 'Ana  Lima', code: '042042' });
  assert.match(subject, /FitCoach/);
  assert.match(text, /^Olá, Ana\./);
  assert.match(text, /042042/);
  assert.match(text, /15 minutos/);
  assert.ok(!/<|>|https?:/.test(text));
  assert.match(pr.resetMessage({ name: '', code: '000000' }).text, /^Olá\./);
  assert.match(pr.resetMessage({ name: '\u0000\n', code: '000000' }).text, /^Olá\./);
});
