# LendBridge — Portfolio 4: NoSQL with MongoDB

MIT 8103 Advanced Database Systems  
Execution date: 26 October 2026  
Status: database exercises verified; personal reflection and final submission review remain.

## 1\. Purpose and storage decision

LendBridge is a fictional fintech providing working-capital lending to Nigerian MSMEs. MongoDB stores flexible KYC enrichment profiles, activity events and temporary login sessions. PostgreSQL remains the authoritative source for borrowers, lending decisions, disbursements, repayment allocation and financial balances. A MongoDB KYC status is synthetic enrichment data and does not authorise a loan or override the relational financial records.

## 2\. Cross-database link

The reference is `lendbridge\_db.lb\_bench.borrowers.borrower\_id`, using the benchmark borrowers from Portfolio 2. The PostgreSQL preflight returned 5,000 rows, 5,000 distinct identifiers, minimum 1, maximum 5,000 and zero missing identifiers. The MongoDB generator uses the same identifier range and the business-name convention `Synthetic MSME <id>`.

Each profile records `source\_ref` with database `lendbridge\_db`, schema `lb\_bench` and table `borrowers`. This is descriptive metadata, not a connection or replication mechanism. MongoDB does not enforce a foreign key against PostgreSQL. Referential coverage was checked before seeding; no live cross-database synchronisation was implemented. An operational implementation would require controlled event delivery, idempotent processing, reconciliation and explicit handling of deleted or changed source records.

## 3\. Document model

|Collection|Role|Design choice|
|-|-|-|
|`kyc\_profiles`|One enrichment profile per borrower|Embed bounded document metadata; optional risk notes and device fields|
|`audit\_events`|Borrower activity history|Separate events linked by `borrower\_id`, avoiding an unbounded profile array|
|`login\_sessions`|Temporary session records|Separate short-lived documents with a TTL index|

Profiles contain one to three synthetic identity documents in the seed data, depending on profile tier. Validation allows up to ten identity documents and five device entries. Tier 1 has one document, tier 2 has two and tier 3 has three in this dataset. Documents store metadata and synthetic references, rather than actual identity-document scans. Event request amounts use Decimal128 and currency NGN. These amounts represent requests, not approved loans, cash movements or ledger balances.

The seed run produced 5,000 profiles and 100,000 events. Initial event counts were 19,987 application submissions, 20,094 fraud flags, 20,091 KYC submissions, 19,889 failed logins and 19,939 successful logins.

## 4\. Validation

All three collections use strict JSON Schema validation with the error action. Required fields, BSON types, permitted status/event values, positive borrower identifiers and bounded arrays are enforced. Unexpected properties are rejected within the defined structures. Profile status values are PENDING, VERIFIED and REJECTED.

The executed tests rejected an invalid KYC profile, an invalid audit event and an invalid login session with error code **121**. These checks establish structural validation; they do not establish the truth of identity information or the existence of a PostgreSQL borrower. A subsequent uniqueness test rejected a duplicate borrower profile with error **11000**.

## 5\. CRUD and aggregation

Script 03 created a temporary session for borrower 1001, read nested BVN and passport information, retrieved the borrower's latest events, and demonstrated `$set` and `$push` on the profile. It restored the original profile and deleted the temporary session. The displayed remaining temporary-session count was zero. Two demonstration audit events were retained, giving 100,002 total events while preserving the original 100,000 seed events.

Four aggregations were executed: event counts over the fixed 30-day window, daily requested NGN amounts, the five borrowers with the most failed logins joined to their KYC tier, and mean embedded-document counts by tier. The failed-login result included borrowers 884 and 2810 with seven failures each, followed by 2019, 2647 and 2721 with six each. Mean document counts were 1, 2 and 3 for tiers 1, 2 and 3; profile counts were 1,666, 1,667 and 1,667 respectively.

The update and audit inserts are separate operations, not a multi-document transaction. Restoration logic aids the demonstration but does not guarantee an atomic profile change and corresponding audit record under failure. A production workflow would need stronger transactional or reliable event-delivery handling.

### Pipeline explanation and SQL equivalent

The city fraud-flag extension uses `$match` to select FRAUD\_FLAG events in the interval from 26 September 2026 inclusive to 26 October 2026 exclusive, excluding demonstration events. `$group` counts events for each `metadata.city`. `$sort` ranks counts descending, breaking ties alphabetically. `$project` gives the output readable field names. The result counts events, rather than unique borrowers.

The following SQL is a conceptual equivalent for a hypothetical PostgreSQL event mirror with a JSONB metadata column. **No such mirror is required or claimed to exist; this SQL was not executed.**

```sql
SELECT metadata->>'city' AS city,
       COUNT(\*) AS fraud\_flags
FROM audit\_events\_mirror
WHERE event\_type = 'FRAUD\_FLAG'
  AND ts >= TIMESTAMPTZ '2026-09-26 00:00:00+00'
  AND ts <  TIMESTAMPTZ '2026-10-26 00:00:00+00'
  AND COALESCE((metadata->>'demo')::boolean, FALSE) = FALSE
GROUP BY metadata->>'city'
ORDER BY fraud\_flags DESC, city ASC;
```

## 6\. Indexing and performance

The preserved output contains all 18 measurements: three queries, three before runs and three after runs. Results below use the top-level `execution\_ms` measurements, not stage estimates.

|Query|Before runs (ms)|After runs (ms)|Median before → after|Documents examined before → after|Returned|
|-|-|-|-|-|-:|
|Q1: latest 20 historical events for borrower 1001|67, 59, 60|1, 0, 0|60 → 0 ms|100,002 → 20|20|
|Q2: FRAUD\_FLAG events in the fixed last seven days|99, 72, 65|4, 3, 3|72 → 3 ms|100,002 → 1,528|1,528|
|Q3: borrower 2500 profile|4, 3, 3|1, 0, 0|3 → 0 ms|5,000 → 1|1|

Before indexing, Q1 required collection scanning and sorting; Q2 and Q3 used collection scans. After indexing, Q1 and Q2 used IXSCAN within their plans, while Q3 used EXPRESS\_IXSCAN. Keys examined after indexing were 20, 1,528 and 1 respectively, compared with zero before. Returned counts remained unchanged.

|Collection|Index|Purpose|
|-|-|-|
|`audit\_events`|`idx\_borrower\_ts`: borrower\_id ascending, ts descending|Borrower history in timestamp order|
|`audit\_events`|`idx\_type\_ts`: event\_type ascending, ts descending|Event-type filtering within a time interval|
|`kyc\_profiles`|`uq\_borrower\_id`: unique borrower\_id ascending|Profile lookup and one-profile-per-borrower enforcement|
|`login\_sessions`|`ttl\_session\_1h`: created\_at ascending, expireAfterSeconds 3600|Automatic expiry of session documents|

Default `\_id` indexes remain present. The duplicate-profile test passed with code 11000. Both `ttl-expired` and `ttl-fresh` were initially present; the later query returned only `ttl-fresh`, providing evidence that the expired record was removed automatically. TTL processing is asynchronous and should not serve as the sole check of whether a session is authorised at request time.

|Collection|Recorded count|Logical data bytes|Allocated storage bytes|Total index bytes|
|-|-:|-:|-:|-:|
|`audit\_events`|100,002|17,103,473|6,066,176|5,681,152|
|`kyc\_profiles`|5,000|2,266,929|684,032|315,392|
|`login\_sessions`|2 initially|176|24,576|28,672|

These are captured collection statistics, not permanent values; TTL subsequently changed the session count. Index totals include default indexes. A reported zero milliseconds means below millisecond reporting resolution, not zero work. Three local trials on an Atlas Free deployment are a small repeatability check, not a statistically rigorous benchmark. Cache state, shared resources and workload can affect timings; execution statistics also do not represent complete client/network latency. No infinite speedup is claimed.

## 7\. SQL versus MongoDB

PostgreSQL suits LendBridge's authoritative lending and repayment records because relational tables, foreign keys, unique constraints and transactions support explicit relationships and financial invariants. Loan creation and payment allocation can be committed or rolled back as controlled units of work. PostgreSQL also supports JSON data when some attributes vary.

MongoDB suits the supplementary KYC profiles and event workload because documents can contain nested identity metadata and optional enrichment fields without forcing every borrower into identical columns. Embedding bounded identity metadata makes a profile convenient to retrieve, while separate event documents avoid continuously growing profile arrays. Schema validation still matters: flexible storage does not remove the need for required fields, types and permitted values.

Both systems support transactions, including MongoDB multi-document transactions; MongoDB should not be described as inherently non-ACID. Joins can be expressed in SQL or through MongoDB aggregation and `$lookup`, but modelling and indexes determine their cost. Both systems offer scaling approaches, with trade-offs that depend on workload, deployment and operational design. Consistency also depends on the selected configuration and application workflow. In this project, there is no atomic transaction spanning PostgreSQL and MongoDB. For that reason, MongoDB enrichment supports review and analytics, while PostgreSQL retains responsibility for financial truth and lending decisions.

## 8\. Reproduction

Observed environment: Windows PowerShell hosting mongosh **2.14.0**, MongoDB **8.0.34**, existing Atlas **Free** cluster `ADSMivaAz`, AWS Paris. Passwords are entered at a prompt and must not be saved in scripts or committed.

1. Confirm the PostgreSQL borrower identifier coverage described in Section 2.
2. Connect through mongosh and select `lendbridge\_nosql`.
3. Run `01\_schema\_validation.js` and preserve the code-121 results.
4. Run `02\_seed\_data.js` once against empty project collections.
5. Run `03\_crud\_and\_aggregation.js` and preserve its output.
6. Run `04\_indexes\_explain.js` once and preserve the before/after measurements before changing indexes.
7. Inspect the TTL test documents after asynchronous deletion.
8. Run the city fraud-flag query saved as `05\_own\_pipeline.js`.

The random seed is **810304**, and the analytical anchor is **2026-10-26T00:00:00Z**. Fixed windows make the synthetic results reproducible; they are not automatically relative to the day a reader reruns a query. Scripts explicitly target `lendbridge\_nosql` using `getSiblingDB`. Some interactive screenshots show the misspelled selected database `lendbride\_nosql`; this does not change the database targeted explicitly by the scripts. Use the correct name for subsequent interactive work. Selecting a database alone does not create stored data.

The seed script refuses nonempty profile/event collections. The indexing script refuses its already-existing named benchmark indexes to prevent presenting indexed queries as an initial baseline. Do not reset earlier portfolios or rerun destructive setup. Retain original evidence before any intentional controlled rerun. CRUD reruns add further demonstration audit events.

## 9\. Individual extension: fraud flags by city

The assisted extension changes the supplied example from failed-login activity to FRAUD\_FLAG counts by city, uses the fixed 30-day interval, excludes demonstration events and returns a sorted city summary. It was executed interactively and saved as `05\_own\_pipeline.js`.

|City|Fraud-flag events|
|-|-:|
|Lagos|1,362|
|Ibadan|1,348|
|Kano|1,328|
|Port Harcourt|1,316|
|Abuja|1,310|
|**Total**|**6,664**|

Lagos has the largest flag count in this synthetic sample, but the spread is narrow and the generator is artificial. Flags are neither confirmed fraud cases nor city fraud rates. Operational comparison would require exposure denominators, unique-borrower analysis and investigation outcomes. The pipeline can describe review workload, but the sample does not justify real geographic lending restrictions. This extension was developed with AI assistance and should not be represented as independently authored work.

## 10\. Personal reflection

This portfolio helped me understand why LendBridge could use MongoDB alongside PostgreSQL. Working with nested KYC documents showed me how borrowers can have different information while still following validation rules. The indexing exercise made the biggest impression on me. Seeing a query examine 100,002 documents before indexing and only 20 afterwards made the benefit much clearer than execution time alone.



Getting started was challenging. I initially struggled with the database password and pasting commands into MongoDB Shell. Once I resolved those issues, I became more comfortable loading scripts and interpreting the results. I also learned that a fraud flag does not mean fraud has been confirmed, and that session expiry happens asynchronously. If I repeated this work, I would capture the output directly into files from the beginning and organise the evidence as each script finishes.

## 11\. AI-use declaration

I used ChatGPT to help adapt the MongoDB exercises to LendBridge, draft scripts and queries, troubleshoot connection issues, and structure this report. ChatGPT also helped interpret the screenshots and execution output I supplied. I ran the commands in my MongoDB Atlas environment and saved the resulting evidence. The reported performance measurements and aggregation results came from those executions. The fraud-flags-by-city extension was developed with AI assistance. I reviewed the explanations alongside the outputs to support my understanding of the work.

## Evidence index and completion checks

|Evidence location|Content|
|-|-|
|`output/00\_postgres\_borrower\_check.csv`|PostgreSQL preflight|
|`screenshots/00\_postgres\_borrower\_check.png`|Borrower identifier coverage|
|`screenshots/01\_mongodb\_connection.png`|Shell connection and ping|
|`screenshots/02\_schema\_validation.png`|Three code-121 validation passes|
|`screenshots/03\_seed\_counts.png`|Initial counts and event distribution|
|`screenshots/04\_sample\_profiles.png`|Nested profile examples|
|`screenshots/05\_seed\_success.png`|Seed completion|
|`screenshots/03\_crud\_and\_aggregation/`|CRUD and four pipeline screenshots|
|`output/04\_indexes\_explain.txt`|Preserved session transcript, including all 18 performance runs|
|`screenshots/06\_indexes\_and\_ttl.png`|Index definitions and initial TTL-session count|
|`screenshots/07\_ttl\_expired\_deleted.png`|Expired session absent, fresh session retained|
|`screenshots/08\_fraud\_flags\_by\_city.png`|Extension query and city results|

These paths follow the agreed saving instructions; verify that each file exists locally before upload. The transcript contains earlier authentication failures followed by successful execution; those earlier messages are setup history, not index-test failures. Avoid publishing credentials in evidence.

* \[ ] Complete the personal reflection and review the AI-use declaration.
* \[ ] Confirm script 05 contains the executed fraud-flag query rather than the original example.
* \[ ] Confirm all referenced evidence files are present and filenames match.
* \[ ] Review the course's requirement for independent extension work and explain the pipeline yourself.
* \[ ] Upload `portfolio-4-nosql` alongside Portfolios 1–3 and verify GitHub renders this README.
* \[ ] Check required repository visibility and commit-history expectations against the course brief; do not fabricate earlier commits.

## Technical references

* [MongoDB schema validation](https://www.mongodb.com/docs/manual/core/schema-validation/)
* [MongoDB explain results](https://www.mongodb.com/docs/manual/reference/explain-results/)
* [MongoDB TTL indexes](https://www.mongodb.com/docs/manual/core/index-ttl/)
* [MongoDB transactions](https://www.mongodb.com/docs/manual/core/transactions/)

Execution evidence is the source of the measured results; reference documentation explains database behaviour and is not a substitute for that evidence.

