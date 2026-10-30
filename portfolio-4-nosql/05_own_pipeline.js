db.getSiblingDB("lendbridge_nosql").audit_events.aggregate([
  {
    $match: {
      event_type: "FRAUD_FLAG",
      ts: {
        $gte: ISODate("2026-09-26T00:00:00Z"),
        $lt: ISODate("2026-10-26T00:00:00Z")
      },
      "metadata.demo": { $ne: true }
    }
  },
  {
    $group: {
      _id: "$metadata.city",
      fraud_flags: { $sum: 1 }
    }
  },
  { $sort: { fraud_flags: -1, _id: 1 } },
  {
    $project: {
      _id: 0,
      city: "$_id",
      fraud_flags: 1
    }
  }
]).toArray()