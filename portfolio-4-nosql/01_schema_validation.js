// LendBridge Portfolio 4. Run with mongosh, not pgAdmin or Node.
const d = db.getSiblingDB('lendbridge_nosql');
const statusValues = ['PENDING', 'VERIFIED', 'REJECTED'];
const source = {
  bsonType: 'object',
  required: ['database', 'schema', 'table'],
  properties: {
    database: {enum: ['lendbridge_db']},
    schema: {enum: ['lb_bench']}, table: {enum: ['borrowers']}
  }, additionalProperties: false
};
const schemas = {
  kyc_profiles: {
    bsonType: 'object',
    required: ['borrower_id', 'business_name', 'profile_tier', 'status',
      'documents', 'created_at', 'source_ref', 'schema_version'],
    properties: {
      _id: {bsonType: 'objectId'},
      borrower_id: {bsonType: 'int', minimum: 1},
      business_name: {bsonType: 'string', minLength: 1},
      profile_tier: {bsonType: 'int', minimum: 1, maximum: 3},
      status: {enum: statusValues},
      documents: {
        bsonType: 'array', minItems: 1, maxItems: 10,
        items: {
          bsonType: 'object', required: ['type', 'reference', 'status'],
          properties: {
            type: {enum: ['BVN', 'NIN', 'CAC_CERT', 'PASSPORT']},
            reference: {bsonType: 'string', minLength: 1},
            status: {enum: statusValues},
            expires_at: {bsonType: 'date'}
          }, additionalProperties: false
        }
      },
      devices: {bsonType: 'array', maxItems: 5, items: {bsonType: 'string'}},
      risk_notes: {bsonType: 'string'},
      created_at: {bsonType: 'date'}, updated_at: {bsonType: 'date'},
      source_ref: source, schema_version: {bsonType: 'int', enum: [1]}
    }, additionalProperties: false
  },
  audit_events: {
    bsonType: 'object',
    required: ['event_id', 'borrower_id', 'event_type', 'ts', 'metadata'],
    properties: {
      _id: {bsonType: 'objectId'}, event_id: {bsonType: 'string', minLength: 1},
      borrower_id: {bsonType: 'int', minimum: 1},
      event_type: {enum: ['LOGIN_SUCCESS', 'LOGIN_FAILED', 'KYC_SUBMITTED',
        'APPLICATION_SUBMITTED', 'FRAUD_FLAG', 'KYC_UPDATED']},
      ts: {bsonType: 'date'},
      metadata: {
        bsonType: 'object', required: ['city', 'synthetic'],
        properties: {
          city: {bsonType: 'string'}, synthetic: {enum: [true]},
          requested_amount: {bsonType: 'decimal', minimum: Decimal128('0.01')},
          currency: {enum: ['NGN']}, reason: {bsonType: 'string'},
          demo: {bsonType: 'bool'}, run_id: {bsonType: 'string'}
        }, additionalProperties: false
      }
    }, additionalProperties: false
  },
  login_sessions: {
    bsonType: 'object', required: ['borrower_id', 'created_at', 'purpose'],
    properties: {
      _id: {bsonType: 'string'}, borrower_id: {bsonType: 'int', minimum: 1},
      created_at: {bsonType: 'date'}, purpose: {bsonType: 'string'}
    }, additionalProperties: false
  }
};
for (const [name, schema] of Object.entries(schemas)) {
  const options = {validator: {$jsonSchema: schema},
    validationLevel: 'strict', validationAction: 'error'};
  if (d.getCollectionNames().includes(name)) {
    const result = d.runCommand({collMod: name, ...options});
    if (result.ok !== 1) throw Error('Could not set validator: ' + name);
  } else d.createCollection(name, options);
}
function reject(label, collection, bad) {
  try { d[collection].insertOne(bad); }
  catch (e) {
    if (e.code === 121) {print('PASS: ' + label + ' rejected with code 121'); return;}
    throw e;
  }
  // Only clean the deliberately inserted probe if validation unexpectedly failed.
  d[collection].deleteOne({_id: bad._id});
  throw Error('FAIL: invalid ' + label + ' was accepted');
}
reject('KYC profile', 'kyc_profiles', {_id: new ObjectId(), borrower_id: 'wrong'});
reject('audit event', 'audit_events', {_id: new ObjectId(), event_type: 'UNKNOWN'});
reject('login session', 'login_sessions', {_id: 'invalid-validation-probe',
  borrower_id: Int32(1), created_at: 'not-a-date', purpose: 'validation probe'});
printjson(d.getCollectionNames().filter(n => Object.hasOwn(schemas, n)));
print('Validators check types and structure, not PostgreSQL foreign keys or KYC truth.');
