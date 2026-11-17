'use strict';
// Google Places (New) proxy — pure logic. The API key is added by index.js from Secret Manager; it never reaches the app.

const NEARBY_URL = 'https://places.googleapis.com/v1/places:searchNearby';
const FIELD_MASK = 'places.id,places.displayName,places.location';   // ask only for what we use (cost + privacy)

function validateSearch(body) {
  if (!body || typeof body !== 'object') return { ok: false, reason: 'body' };
  const { latitude, longitude } = body;
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90) return { ok: false, reason: 'latitude' };
  if (!Number.isFinite(longitude) || longitude < -180 || longitude > 180) return { ok: false, reason: 'longitude' };
  const requested = Number.isFinite(body.radiusMeters) ? body.radiusMeters : 1000;
  return { ok: true, latitude, longitude, radiusMeters: Math.min(Math.max(requested, 100), 5000) };
}

/** Request for Nearby Search (New). `gym` is a documented Table A place type. */
function buildNearbyRequest({ latitude, longitude, radiusMeters }, maxResults = 10) {
  return {
    url: NEARBY_URL,
    fieldMask: FIELD_MASK,
    body: {
      includedTypes: ['gym'],
      maxResultCount: Math.min(Math.max(Math.trunc(maxResults), 1), 20),
      locationRestriction: { circle: { center: { latitude, longitude }, radius: radiusMeters } },
    },
  };
}

/** Places response → the compact shape the app decodes. Drops anything malformed. */
function mapPlaces(response) {
  const places = response && Array.isArray(response.places) ? response.places : [];
  return places.flatMap((place) => {
    const name = place?.displayName?.text;
    const location = place?.location;
    if (typeof place?.id !== 'string' || !place.id || typeof name !== 'string' || !name) return [];
    if (!Number.isFinite(location?.latitude) || !Number.isFinite(location?.longitude)) return [];
    return [{ id: place.id, name: name.slice(0, 120), latitude: location.latitude, longitude: location.longitude }];
  });
}

module.exports = { NEARBY_URL, FIELD_MASK, validateSearch, buildNearbyRequest, mapPlaces };
