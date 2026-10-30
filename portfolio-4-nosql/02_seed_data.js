// Initial seed only. Refuses to overwrite an existing or partially seeded dataset.
const d = db.getSiblingDB('lendbridge_nosql');
for (const name of ['kyc_profiles', 'audit_events', 'login_sessions']) {
  if (!d.getCollectionNames().includes(name)) throw Error('Run 01_schema_validation.js first');
}
if (d.kyc_profiles.countDocuments({}) || d.audit_events.countDocuments({})) {
  throw Error('Seed stopped: profiles/events already exist. Do not rerun over evidence.');
}
// Fixed event time boundary: use this same cutoff in every analytical script.
const anchor = new Date('2026-10-26T00:00:00.000Z');
const day = 86400000;
let state = 810304;
function random() {state = (Math.imul(1664525, state) + 1013904223) >>> 0;
  return state / 4294967296;}
const types = ['LOGIN_SUCCESS', 'LOGIN_FAILED', 'KYC_SUBMITTED',
  'APPLICATION_SUBMITTED', 'FRAUD_FLAG'];
const cities = ['Lagos', 'Abuja', 'Kano', 'Ibadan', 'Port Harcourt'];
const statuses = ['PENDING', 'VERIFIED', 'REJECTED'];
let profiles = [], events = [], eventNumber = 0;
for (let id = 1; id <= 5000; id++) {
  const tier = 1 + (id % 3), status = statuses[id % 3];
  const documents = [{type: 'BVN', reference: 'SYNTHETIC-BVN-' + id, status}];
  if (tier >= 2) documents.push({type: 'CAC_CERT',
    reference: 'SYNTHETIC-CAC-' + id, status});
  if (tier === 3) documents.push({type: 'PASSPORT',
    reference: 'SYNTHETIC-PASSPORT-' + id, status,
    expires_at: new Date(anchor.getTime() + (30 + id % 700) * day)});
  const profile = {borrower_id: Int32(id), business_name: 'Synthetic MSME ' + id,
    profile_tier: Int32(tier), status, documents,
    created_at: new Date(anchor.getTime() - 90 * day),
    source_ref: {database: 'lendbridge_db', schema: 'lb_bench', table: 'borrowers'},
    schema_version: Int32(1)};
  if (tier === 3) profile.risk_notes = 'Synthetic enhanced review example';
  if (id % 4 === 0) profile.devices = ['synthetic-device-' + id];
  profiles.push(profile);
  for (let j = 0; j < 20; j++) {
    const type = types[Math.floor(random() * types.length)];
    const metadata = {city: cities[id % cities.length], synthetic: true};
    if (type === 'APPLICATION_SUBMITTED') {
      metadata.requested_amount = Decimal128(String(20000 + Math.floor(random()*1981)*1000));
      metadata.currency = 'NGN';
    }
    if (type === 'FRAUD_FLAG') metadata.reason = 'Synthetic anomaly for review';
    events.push({event_id: 'seed-' + String(++eventNumber).padStart(6, '0'),
      borrower_id: Int32(id), event_type: type,
      ts: new Date(anchor.getTime() - Math.floor(random() * 90 * day)), metadata});
    if (events.length === 1000) {d.audit_events.insertMany(events); events = [];}
  }
  if (profiles.length === 500) {d.kyc_profiles.insertMany(profiles); profiles = [];}
}
if (events.length) d.audit_events.insertMany(events);
if (profiles.length) d.kyc_profiles.insertMany(profiles);
const counts = {kyc_profiles: d.kyc_profiles.countDocuments({}),
  audit_events: d.audit_events.countDocuments({})};
printjson({seed: 810304, analytical_anchor: anchor, source: 'lb_bench.borrowers', ...counts});
if (counts.kyc_profiles !== 5000 || counts.audit_events !== 100000) throw Error('Seed count mismatch');
printjson(d.audit_events.aggregate([{$group: {_id: '$event_type', count: {$sum: 1}}},
  {$sort: {_id: 1}}]).toArray());
printjson(d.kyc_profiles.findOne({borrower_id: Int32(2)})); // Tier 3
printjson(d.kyc_profiles.findOne({borrower_id: Int32(3)})); // Tier 1
print('PASS: 5000 profiles and 100000 events. Counts are initial seed counts.');
