'use strict';
// Fixed-window per-user limiter (the Places API is billed per call). Pure: the caller loads/stores the counter doc.

function consume(counter, nowMs, { limit, windowMs }) {
  const fresh = !counter || !(counter.windowStart + windowMs > nowMs);
  const state = fresh ? { windowStart: nowMs, count: 0 } : { windowStart: counter.windowStart, count: counter.count };
  if (state.count >= limit) {
    return { allowed: false, next: state, retryAfterSeconds: Math.max(1, Math.ceil((state.windowStart + windowMs - nowMs) / 1000)) };
  }
  return { allowed: true, next: { windowStart: state.windowStart, count: state.count + 1 } };
}

module.exports = { consume };
