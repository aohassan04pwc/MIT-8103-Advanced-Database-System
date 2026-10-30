const d = db.getSiblingDB('lendbridge_nosql');
const anchor = new Date('2026-10-26T00:00:00.000Z'), day = 86400000;
const runId = new ObjectId().toHexString();
// Demo uses an existing benchmark borrower, not a fictitious extra PG borrower.
const original = d.kyc_profiles.findOne({borrower_id: Int32(1001)});
if (!original) throw Error('Borrower 1001 profile missing. Run the seed first.');
let temporaryId = null;
try {
  print('CREATE: temporary login session for existing borrower 1001');
  temporaryId = 'crud-' + runId;
  d.login_sessions.insertOne({_id: temporaryId, borrower_id: Int32(1001),
    created_at: new Date(), purpose: 'Temporary CRUD demonstration'});
  printjson(d.login_sessions.findOne({_id: temporaryId}));
  print('READ: nested BVN query and passport expiry with $elemMatch');
  printjson(d.kyc_profiles.find({'documents.type': 'BVN'}).limit(2).toArray());
  printjson(d.kyc_profiles.find({documents: {$elemMatch: {type: 'PASSPORT',
    expires_at: {$gte: anchor, $lt: new Date(anchor.getTime()+365*day)}}}}).limit(2).toArray());
  print('READ: latest 20 events for borrower 1001');
  printjson(d.audit_events.find({borrower_id: Int32(1001)})
    .sort({ts: -1}).limit(20).toArray());
  print('UPDATE: demonstrate $set and $push on borrower 1001');
  d.kyc_profiles.updateOne({_id: original._id}, {
    $set: {status: 'VERIFIED', profile_tier: Int32(3), updated_at: new Date()},
    $push: {documents: {type: 'NIN', reference: 'SYNTHETIC-DEMO-' + runId, status: 'VERIFIED'}}
  });
  d.audit_events.insertOne({event_id: 'crud-update-' + runId,
    borrower_id: Int32(1001), event_type: 'KYC_UPDATED', ts: new Date(),
    metadata: {city: 'Lagos', synthetic: true, demo: true, run_id: runId,
      reason: 'Temporary profile edit; restored at end of demo'}});
  printjson(d.kyc_profiles.findOne({_id: original._id}));
} finally {
  // Restore the exact seeded document, even if a demonstration operation throws.
  d.kyc_profiles.replaceOne({_id: original._id}, original);
  d.audit_events.insertOne({event_id: 'crud-restore-' + runId,
    borrower_id: Int32(1001), event_type: 'KYC_UPDATED', ts: new Date(),
    metadata: {city: 'Lagos', synthetic: true, demo: true, run_id: runId,
      reason: 'Restoration after temporary edit attempted; see script outcome'}});
  print('DELETE: remove only the temporary login session');
  if (temporaryId) d.login_sessions.deleteOne({_id: temporaryId});
  printjson({temporary_session_remaining: d.login_sessions.countDocuments({_id: temporaryId})});
}
// Not a cross-document transaction: update/event write could diverge on failure.
// This teaching demo restores state; production needs transactional/outbox design.
const window30 = {ts: {$gte: new Date(anchor.getTime()-30*day), $lt: anchor},
  'metadata.demo': {$ne: true}};
print('AGGREGATION 1: event counts in 30 days before the fixed anchor');
printjson(d.audit_events.aggregate([
  {$match: window30}, {$group: {_id: '$event_type', count: {$sum: 1}}},
  {$sort: {count: -1, _id: 1}}
]).toArray());
print('AGGREGATION 2: requested NGN per UTC day, not cash disbursed or received');
printjson(d.audit_events.aggregate([
  {$match: {...window30, event_type: 'APPLICATION_SUBMITTED'}},
  {$group: {_id: {$dateToString: {format: '%Y-%m-%d', date: '$ts', timezone: 'UTC'}},
    requested_ngn: {$sum: '$metadata.requested_amount'}, applications: {$sum: 1}}},
  {$sort: {_id: 1}}
]).toArray());
print('AGGREGATION 3: top 5 failed-login borrowers and their KYC tier');
printjson(d.audit_events.aggregate([
  {$match: {...window30, event_type: 'LOGIN_FAILED'}},
  {$group: {_id: '$borrower_id', failures: {$sum: 1}}},
  {$sort: {failures: -1, _id: 1}}, {$limit: 5},
  {$lookup: {from: 'kyc_profiles', localField: '_id', foreignField: 'borrower_id', as: 'profile'}},
  {$unwind: {path: '$profile', preserveNullAndEmptyArrays: true}},
  {$project: {_id: 0, borrower_id: '$_id', failures: 1,
    business_name: '$profile.business_name', profile_tier: '$profile.profile_tier'}}
]).toArray());
print('AGGREGATION 4: average embedded document count per profile tier');
printjson(d.kyc_profiles.aggregate([
  {$project: {profile_tier: 1, document_count: {$size: '$documents'}}},
  {$group: {_id: '$profile_tier', mean_documents: {$avg: '$document_count'}, profiles: {$sum: 1}}},
  {$sort: {_id: 1}}
]).toArray());
printjson({profiles: d.kyc_profiles.countDocuments({}),
  total_events: d.audit_events.countDocuments({}),
  seed_events: d.audit_events.countDocuments({event_id: /^seed-/}),
  demo_events: d.audit_events.countDocuments({'metadata.demo': true})});
