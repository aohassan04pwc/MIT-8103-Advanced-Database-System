# LendBridge Relational Database Normalisation

**Module:** MIT 8103 Advanced Database Systems  
**Portfolio:** Portfolio 1

This report explains how a hypothetical spreadsheet representation can be decomposed into the eight LendBridge tables. LendBridge is fictional; the spreadsheet is a teaching example, not evidence of an actual organisation's operating history. Amounts below are NGN.

## Unnormalised form

A wide tracker might mix borrower identity, product definitions, application decisions, loan terms, KYC documents, instalments, receipts and allocations in one record.

| Borrower | Application | Contract | KYC submissions | Instalments | Receipts and allocations |
|---|---|---|---|---|---|
| Amina Bello, borrower 101, amina@example.test | Application 201, product 301, requested 300000 | Loan 401, principal 300000, full-term rate 0.06, term 3 months | BVN verified; CAC verified | 501: 106000; 502: 106000; 503: 106000 | Receipt 601: 120000 split 106000 to 501 and 14000 to 502; receipt 602: 92000 to 502 |

The list-valued cells contain repeating groups. The example identifiers are explanatory labels, not IDs to insert into the implemented database.

This representation risks update anomalies when a phone number is repeated, insertion anomalies when a product cannot be recorded without a loan, and deletion anomalies when removing the last payment row also removes information about an unrelated borrower or product.

## First normal form

1NF requires atomic values in each attribute and identifiable rows without repeating groups. Replace the lists with separate rows at their own grain: one KYC submission, one application, one loan, one instalment, one receipt and one allocation per record. Do not create a Cartesian product between independent KYC, instalment and receipt lists.

To illustrate the dependencies still present, consider this allocation extract after atomic values have been introduced:

| repayment_id | instalment_id | loan_id | borrower_id | borrower_name | receipt_amount | instalment_due | allocated_amount |
|---|---|---|---|---|---|---|---|
| 601 | 501 | 401 | 101 | Amina Bello | 120000 | 106000 | 106000 |
| 601 | 502 | 401 | 101 | Amina Bello | 120000 | 106000 | 14000 |
| 602 | 502 | 401 | 101 | Amina Bello | 92000 | 106000 | 92000 |

Use `(repayment_id, instalment_id)` consistently as the candidate key for this extract under the rule that a receipt has at most one allocation row for an instalment. Borrower email is not part of the key. Neither component alone is unique: repayment 601 spans two instalments and instalment 502 receives two payments.

The extract covers existing allocations only. It cannot replace the records for unpaid instalments, unapplied receipts, pending applications, unused products or KYC submissions. Those must be preserved separately throughout the decomposition.

## Second normal form

2NF requires 1NF and no partial dependence of a non-prime attribute on a proper subset of a candidate key. A non-prime attribute is one that belongs to no candidate key. The dependencies in the extract include:

| Determinant | Dependent facts | Reason for separation |
|---|---|---|
| `repayment_id` | `loan_id`, receipt amount, provider reference, idempotency key, receipt time | These depend on the receipt alone |
| `instalment_id` | `loan_id`, instalment number, due date, principal due and interest due | These depend on the instalment alone |
| `(repayment_id, instalment_id)` | Allocated amount and allocation time | These describe the particular receipt-to-instalment pairing |

Separate the payment-related facts into:

- `repayments(repayment_id, loan_id, provider_reference, idempotency_key, amount, received_at)`.
- `instalments(instalment_id, loan_id, instalment_no, due_date, principal_due, interest_due)`.
- `repayment_allocations(repayment_id, instalment_id, allocated_amount, allocated_at)`.

The allocation table's composite key prevents duplicate pairings. Its non-key attributes describe the whole pairing. The receipt and instalment keys retain the relationships without repeating their facts on every allocation.

For the remaining loan context, an intermediate teaching relation might hold a loan ID, application ID, borrower ID and contact fields, product ID and current product fields, plus historical contract terms. Its transitive dependencies are addressed next. Separate KYC and application records preserve cases with no disbursement.

## Third normal form

Formally, for every non-trivial functional dependency `X -> A`, 3NF requires that `X` is a superkey or `A` is a prime attribute. Requiring every determinant to be a superkey is the stronger BCNF condition. In this project's descriptive entity tables, the practical aim is to remove non-key facts that depend on another non-key identifier.

In an intermediate loan-context relation:

- `application_id -> borrower_id, product_id, requested_amount, application decision facts`.
- `borrower_id -> first_name, last_name, business_name, email, phone`.
- `product_id -> product_name, current product limits, current product term, current product rate, active`.

Move borrower details to `borrowers`, current product facts to `loan_products`, application requests and decisions to `loan_applications`, and individual identity submissions to `kyc_records`. A KYC submission is not flattened into a borrower row because the borrower can have multiple submissions.

The completed model has the following eight tables:

| Table | Primary key | Principal facts |
|---|---|---|
| `borrowers` | `borrower_id` | Name, business, email, phone and creation time |
| `kyc_records` | `kyc_id` | Borrower, document type and reference, status and decision times |
| `loan_products` | `product_id` | Name, minimum and maximum amounts, term, rate and active flag |
| `loan_applications` | `application_id` | Borrower, product, requested amount, purpose, decision and supporting KYC |
| `loans` | `loan_id` | Application, reference, contracted principal, rate, term and disbursement time |
| `instalments` | `instalment_id` | Loan, instalment number, due date, principal due and interest due |
| `repayments` | `repayment_id` | Loan, provider reference, idempotency key, amount and receipt time |
| `repayment_allocations` | `(repayment_id, instalment_id)` | Allocated amount and allocation time |

Additional candidate keys matter as well: borrower email and phone; product name; loan application ID and loan reference; instalment `(loan_id, instalment_no)`; repayment provider reference and idempotency key. A surrogate primary key does not automatically make a table normalised.

The foreign keys preserve the entity associations. The allocation table can be joined back to its receipt and instalment without losing their facts. The workflow rule requiring both parents to belong to the same loan is enforced separately by the allocation trigger. Normalisation alone does not enforce that rule or guarantee schedule completeness.

## Deliberate stored values and their tradeoffs

### Historical loan contract terms

Current product terms and disbursed contract terms have different meanings. If a product's rate changes from 6% to 8%, an existing loan must retain its agreed 6% rate. The loan therefore stores the contracted principal, rate and term. It does not dynamically reprice itself from the current product catalogue.

The contract trigger protects principal, rate, term and application linkage against updates. Correct copying at disbursement is still necessary. The source procedure reads the current product terms when disbursing, so it does not separately preserve terms at the earlier application-approval time.

### Stored generated instalment total

The implemented `instalments` table also includes:

```sql
total_due NUMERIC(19,2)
GENERATED ALWAYS AS (principal_due + interest_due) STORED
```

This stores a value derivable from other non-key attributes. In strict dependency analysis, it is a deliberate departure from a purely 3NF physical representation. PostgreSQL maintains the expression automatically, reducing the risk of separately entering an inconsistent total. The tradeoff is additional storage and the need to distinguish the normalised logical facts from this convenient physical derived column. The table is not claimed to be strictly 3NF including every stored derived attribute.

### Balances calculated through views

Outstanding debt is calculated as scheduled dues less allocations. Unapplied cash is receipt amount less receipt allocations. There is no separately maintained outstanding-balance column in the supplied tables.

This avoids one source of duplicated balance state, but a view cannot prevent incorrect source data, unauthorised edits or concurrency errors. Stored balance caches can be valid in other designs when updated transactionally and independently reconciled; they are not inherently forbidden by normalisation.

## Worked repayment example

For a principal of 300000 at 6% flat interest over three months:

- Interest is 18000; total contractual repayment is 318000.
- Three instalments are 106000 each.
- A 120000 payment allocates 106000 to instalment 1 and 14000 to instalment 2.
- A 92000 payment completes instalment 2.
- A 150000 payment allocates 106000 to instalment 3 and leaves 44000 unapplied.

The corrected test suite verified these allocations and totals in isolated test records, then rolled the records back. The test report is evidence of that scenario; it does not mean a retained loan with those receipts exists in the seed database.

## Student explanation

Before submission, the student should explain the grain of each table, the allocation composite key, at least one partial and one transitive dependency, and the reason historical terms and generated totals are treated differently. See the [README](README.md) for execution evidence and the AI use declaration.
