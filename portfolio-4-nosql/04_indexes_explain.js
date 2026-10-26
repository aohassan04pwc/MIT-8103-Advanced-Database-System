const d = db.getSiblingDB('lendbridge_nosql');
const anchor = new Date('2026-10-26T00:00:00.000Z'), day = 86400000;
const indexNames = [
  [d.audit_events, 'idx_borrower_ts'],
  [d.audit_events, 'idx_type_ts'],
  [d.kyc_profiles, 'uq_borrower_id']
];
// Refuse a misleading 'before' capture on a previously indexed database.
for (const [c, name] of indexNames) {
  if (c.getIndexes().some(i => i.name === name)) {
    throw Error('Baseline stopped: ' + name + ' exists. Preserve evidence; see rerun instructions.');
  }
}
print('BASELINE INDEX INVENTORY');
printjson({audit_events: d.audit_events.getIndexes(), kyc_profiles: d.kyc_profiles.getIndexes()});
function queries() {
  return [
    ['Q1', () => d.audit_events.find({borrower_id: Int32(1001), ts: {$lt: anchor}})
      .sort({ts: -1}).limit(20)],
    ['Q2', () => d.audit_events.find({event_type: 'FRAUD_FLAG',
      ts: {$gte: new Date(anchor.getTime()-7*day), $lt: anchor}})],
    ['Q3', () => d.kyc_profiles.find({borrower_id: Int32(2500)})]
  ];
}
function capture(phase) {
  for (const [query, cursor] of queries()) {
    for (let run = 1; run <= 3; run++) {
      const e = cursor().explain('executionStats'), s = e.executionStats;
      printjson({phase, query, run, returned: s.nReturned,
        documents_examined: s.totalDocsExamined, keys_examined: s.totalKeysExamined,
        execution_ms: s.executionTimeMillis,
        winning_plan: e.queryPlanner.winningPlan,
        execution_stages: s.executionStages});
    }
  }
}
capture('BEFORE');
d.audit_events.createIndex({borrower_id: 1, ts: -1}, {name: 'idx_borrower_ts'});
d.audit_events.createIndex({event_type: 1, ts: -1}, {name: 'idx_type_ts'});
d.kyc_profiles.createIndex({borrower_id: 1}, {name: 'uq_borrower_id', unique: true});
capture('AFTER');
const duplicate = d.kyc_profiles.findOne({borrower_id: Int32(1)});
duplicate._id = new ObjectId();
let rejected = false;
try { d.kyc_profiles.insertOne(duplicate); }
catch (e) {if (e.code !== 11000) throw e; rejected = true; print('PASS: duplicate borrower rejected code 11000');}
if (!rejected) {d.kyc_profiles.deleteOne({_id: duplicate._id}); throw Error('Unique index test failed');}
d.login_sessions.createIndex({created_at: 1}, {name: 'ttl_session_1h', expireAfterSeconds: 3600});
const now = new Date();
for (const [id, hours] of [['ttl-fresh', 0], ['ttl-expired', 2]]) {
  d.login_sessions.replaceOne({_id: id}, {_id: id, borrower_id: Int32(1001),
    created_at: new Date(now.getTime()-hours*3600000), purpose: 'TTL evidence'}, {upsert: true});
}
print('TTL_INITIAL: automatic deletion is asynchronous; inspect again later.');
printjson(d.login_sessions.find({_id: {$in: ['ttl-fresh', 'ttl-expired']}}).toArray());
for (const name of ['audit_events', 'kyc_profiles', 'login_sessions']) {
  print('INDEXES: ' + name); printjson(d[name].getIndexes());
  try {
    const s = d.runCommand({collStats: name});
    if (s.ok !== 1) printjson({collection: name, sizes_unavailable: true, reason: s.errmsg});
    else printjson({collection: name, count: s.count, data_bytes: s.size,
      storage_bytes: s.storageSize, index_bytes: s.totalIndexSize});
  } catch (e) {printjson({collection: name, sizes_unavailable: true, reason: e.message});}
}
