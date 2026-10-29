// Run in mongosh connected to Atlas.
// Reuses the demonstration ID so repeated runs do not add duplicates.

var cloudDb = db.getSiblingDB("lendbridge_cloud");

printjson(cloudDb.runCommand({ ping: 1 }));

var topology = cloudDb.adminCommand({ hello: 1 });
printjson({
  setName: topology.setName,
  primary: topology.primary,
  hosts: topology.hosts,
  isWritablePrimary: topology.isWritablePrimary
});

printjson(cloudDb.replication_events.updateOne(
  { _id: "p5-majority-demo-01" },
  {
    $setOnInsert: {
      event_type: "repayment_received",
      loan_id: 100,
      amount: NumberDecimal("56000.00"),
      currency: "NGN",
      note: "Portfolio 5 cloud replication demonstration",
      created_at: new Date()
    }
  },
  {
    upsert: true,
    writeConcern: { w: "majority", wtimeout: 10000 }
  }
));

printjson(
  cloudDb.replication_events
    .find({ _id: "p5-majority-demo-01" })
    .readPref("secondary")
    .readConcern("majority")
    .maxTimeMS(10000)
    .toArray()
);