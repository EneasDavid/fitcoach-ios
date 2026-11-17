'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const r = require('../lib/registrations');

const SECRET = 'test-secret';

test('CPF: valid ones normalise to digits; bad check digits, repeats and junk are refused', () => {
  assert.equal(r.normalizeCpf('529.982.247-25'), '52998224725');
  assert.equal(r.normalizeCpf(' 111 444 777 35 '), '11144477735');
  for (const bad of ['529.982.247-26', '111.111.111-11', '123', '', '529.982.247-2a', null, 12345678901]) assert.equal(r.normalizeCpf(bad), null);
});

test('CREF: spellings normalise; wrong state, category or digits are refused', () => {
  assert.equal(r.normalizeCref('012345-g/al'), '012345-G/AL');
  assert.equal(r.normalizeCref('CREF 12345 P/SP'), '012345-P/SP');
  assert.equal(r.normalizeCref('cref1234-G/RJ'), '001234-G/RJ');
  for (const bad of ['012345-G/XX', '012345-X/AL', '123-G/AL', '1234567-G/AL', '012345-G', 'G/AL', 'abc', null]) assert.equal(r.normalizeCref(bad), null);
});

test('names: two words of letters, spacing collapsed; matching ignores case, accents and spacing only', () => {
  assert.equal(r.normalizeName('  Maria   Souza '), 'Maria Souza');
  assert.equal(r.normalizeName("Ana-Clara D'Ávila"), "Ana-Clara D'Ávila");
  for (const bad of ['Maria', '', '123 456', 'Maria <script>', 'a '.repeat(80), null]) assert.equal(r.normalizeName(bad), null);
  assert.equal(r.namesMatch('JOSÉ  da Silva', 'jose da silva'), true);
  assert.equal(r.namesMatch('Ana Souza', 'Ana Sousa'), false);
  assert.equal(r.namesMatch('José da Silva', 'José da Silva Junior'), false);
});

test('the registration key and the login alias are keyed (secret-dependent), stable, and never contain the CPF', () => {
  const key = r.registrationKey(SECRET, '52998224725');
  assert.equal(key, r.registrationKey(SECRET, '52998224725'));
  assert.notEqual(key, r.registrationKey('other-secret', '52998224725'));       // brute-forcing needs the server secret
  assert.notEqual(key, r.registrationKey(SECRET, '11144477735'));
  assert.equal(key.includes('52998224725'), false);
  const alias = r.loginAlias(SECRET, '52998224725');
  assert.match(alias, /^[0-9a-f]{40}@students\.fitcoach\.invalid$/);
  assert.notEqual(alias, r.loginAlias(SECRET, '11144477735'));
  assert.notEqual(r.loginAlias(SECRET, 'x'), key);                              // different purpose → different value
});

test('the login alias is computed for any input (no lookup), so it cannot reveal who is registered', () => {
  assert.match(r.loginAlias(SECRET, 'a-cpf-nobody-registered'), /@students\.fitcoach\.invalid$/);
  assert.equal(r.loginAlias(SECRET, 'same'), r.loginAlias(SECRET, 'same'));
});

test('claim: unknown CPF and wrong name give the same 404; an already-used registration is a 409', () => {
  const stored = { fullName: 'Maria Souza', status: 'invited' };
  assert.deepEqual(r.decideClaim(undefined, 'Maria Souza'), { ok: false, status: 404, error: 'not-found' });
  assert.deepEqual(r.decideClaim(stored, 'Maria Sousa'), { ok: false, status: 404, error: 'not-found' });
  assert.deepEqual(r.decideClaim(stored, 'MARIA  souza'), { ok: true });
  assert.deepEqual(r.decideClaim({ ...stored, status: 'active' }, 'Maria Souza'), { ok: false, status: 409, error: 'already-claimed' });
});

test('profile: e-mail shape, age 12–100, known gender, height 100–250 cm, weight 20–400 kg, password 8–128', () => {
  const good = { email: ' Ana@Example.COM ', age: 30, gender: 'female', heightCm: 165.04, weightKg: 60.26, password: 'longenough' };
  assert.deepEqual(r.validateProfile(good), { ok: true, profile: { email: 'ana@example.com', age: 30, gender: 'female', heightCm: 165, weightKg: 60.3 }, password: 'longenough' });
  for (const [patch, reason] of [[{ email: 'ana' }, 'email'], [{ email: 'a@b' }, 'email'], [{ age: 11 }, 'age'], [{ age: 101 }, 'age'], [{ age: '30' }, 'age'],
    [{ gender: 'x' }, 'gender'],
    [{ heightCm: 99 }, 'height'], [{ heightCm: 251 }, 'height'], [{ heightCm: '170' }, 'height'], [{ heightCm: NaN }, 'height'],
    [{ weightKg: 19 }, 'weight'], [{ weightKg: 401 }, 'weight'], [{ weightKg: undefined }, 'weight'], [{ password: 'short' }, 'password'], [{ password: 'x'.repeat(129) }, 'password']]) {
    assert.deepEqual(r.validateProfile({ ...good, ...patch }), { ok: false, reason });
  }
  assert.equal(r.validateProfile(null).ok, false);
});

test('tokens: random, bound to a registration, expire, and only the hash is stored', () => {
  const fixed = () => Buffer.alloc(32, 7);
  const { token, record } = r.newToken('reg-1', 1_000, fixed);
  assert.equal(token.length, 64);
  assert.equal(record.tokenHash, r.tokenHash(token));
  assert.equal('token' in record, false);
  assert.deepEqual(r.validateToken(record, 1_001), { ok: true, registrationId: 'reg-1' });
  assert.deepEqual(r.validateToken(record, 1_000 + r.TOKEN_TTL_MS), { ok: false, reason: 'expired' });
  assert.deepEqual(r.validateToken(undefined, 1), { ok: false, reason: 'unknown-token' });
  assert.notEqual(r.newToken('reg-1', 1).token, r.newToken('reg-1', 1).token);
});

test('attempt limiter: counts inside the window, blocks at the limit, resets after it', () => {
  const policy = { limit: 5, windowMs: 60_000 };
  let counter;
  for (let i = 0; i < 5; i += 1) { const result = r.consumeAttempt(counter, 1_000 + i, policy); assert.equal(result.allowed, true); counter = result.next; }
  const blocked = r.consumeAttempt(counter, 10_000, policy);
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.retryAfterSeconds, 51);
  assert.equal(r.consumeAttempt(counter, 61_001, policy).allowed, true);
});

test('masked CPF shows only the middle digits', () => {
  assert.equal(r.maskCpf('52998224725'), '***.982.247-**');
  assert.equal(r.maskCpf('1'), '***');
});
