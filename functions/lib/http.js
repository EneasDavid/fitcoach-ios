'use strict';
// Request plumbing shared by the HTTP functions. Verifiers are injected, so this is testable without Firebase.

function bearerToken(headerValue) {
  const match = /^Bearer\s+(\S+)$/i.exec(headerValue || '');
  return match ? match[1] : null;
}

/**
 * Requires a valid Firebase ID token AND a valid App Check token (the request came from a genuine build of the app).
 * `verifyIdToken(token)` → { uid } and `verifyAppCheck(token)` must throw on failure.
 */
async function authenticate(headers, { verifyIdToken, verifyAppCheck }) {
  const idToken = bearerToken(headers.authorization);
  const appCheck = headers['x-firebase-appcheck'];
  if (!idToken) return { ok: false, status: 401, error: 'missing-token' };
  if (!appCheck) return { ok: false, status: 401, error: 'missing-app-check' };
  try {
    await verifyAppCheck(appCheck);
  } catch {
    return { ok: false, status: 401, error: 'bad-app-check' };
  }
  try {
    const decoded = await verifyIdToken(idToken);
    return decoded && decoded.uid ? { ok: true, uid: decoded.uid } : { ok: false, status: 401, error: 'bad-token' };
  } catch {
    return { ok: false, status: 401, error: 'bad-token' };
  }
}

module.exports = { bearerToken, authenticate };
