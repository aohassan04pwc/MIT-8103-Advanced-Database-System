# LendBridge Working Capital Lending Case Study

**Module:** MIT 8103 Advanced Database Systems  
**Portfolio:** Portfolio 1  
**Database:** PostgreSQL

## Organisation and business problem

LendBridge is a fictional Nigerian fintech designed for this academic project. It offers NGN working capital loans to traders, retailers, small manufacturers and service businesses. Lagos market traders, auto-parts merchants and logistics operators provide useful examples of intended customers; they are not evidence of real LendBridge operations.

The scenario assumes that loan applications, KYC decisions, repayment schedules and receipts would otherwise be tracked in separate spreadsheets. The database addresses risks of duplicate contact records, approving the wrong applicant's KYC, loans outside product limits, changing historical contract terms, rounding differences, duplicate payment callbacks and incorrect partial-payment allocations.

## System purpose and scope

The system records each stage from borrower registration through application review, disbursement, schedule generation, payment recording and allocation. PostgreSQL is authoritative for these relational records. Payment gateway interactions are simulated with synthetic references; there is no live gateway or bank integration.

The four seed products are:

| Product | Minimum NGN | Maximum NGN | Term months | Flat rate for full term |
|---|---|---|---|---|
| Nano Working Capital 1M | 20000 | 100000 | 1 | 3% |
| Micro Trader 3M | 50000 | 500000 | 3 | 6% |
| SME Growth 6M | 200000 | 2000000 | 6 | 12% |
| Commercial Enterprise 12M | 1000000 | 10000000 | 12 | 20% |

These are illustrative project terms, not advertised lending offers. No compounding, fees, penalties, foreign exchange, joint lending, loan restructuring or general-ledger accounting is implemented.

Each application has one borrower and one product. A borrower may submit multiple applications. An approved application may remain undisbursed; it produces at most one loan. The schema has no active-application count limit or rule limiting a borrower to one active loan.

## Actors and operations

| Actor | Intended operations | Implemented mechanism or scope |
|---|---|---|
| Borrower | Register, submit identity references, apply and inspect repayment status | Relational records and queries; a borrower-facing application is not built |
| Credit officer | Review KYC and approve or reject applications | `sp_approve_application` and `sp_reject_application` |
| Loan operations service | Disburse approved requests and generate schedules | `sp_disburse_loan` |
| Payment processing service | Record a confirmed synthetic receipt and allocate it | `sp_process_repayment` |
| Collections officer | Identify unpaid overdue instalments | Intended reporting through schedule and balance views |
| Audit and reporting officer | Inspect relationships and reconcile receipts with allocations | Reporting views and independently aggregated test totals |

These actors describe responsibilities. Separate PostgreSQL roles and least-privilege grants have not been demonstrated in the supplied scripts. The walkthrough used the `postgres` account.

## Main use case

**Use case:** Approve and service a small business working capital loan.

**Primary actors:** Credit officer, loan operations service and payment processing service.  
**Supporting actors:** Borrower, collections officer and reporting officer.

**Preconditions:** A borrower, product and application exist. Approval needs a verified KYC record belonging to the applicant and an active product with suitable amount limits.

1. The borrower submits an application specifying the product, amount and purpose.
2. The credit officer invokes the approval procedure with the application ID, supporting KYC ID and decision reason.
3. The procedure locks the application, checks its SUBMITTED state, validates KYC ownership and verification, checks product eligibility and records approval.
4. The disbursement procedure locks the approved application, prevents a second loan, captures contractual terms and creates the complete instalment schedule atomically.
5. A confirmed synthetic payment is passed to the repayment procedure with provider reference, idempotency key and amount.
6. The procedure locks the loan, checks for an existing receipt and allocates a new payment to instalments in order until the payment or unpaid debt is exhausted.
7. Reporting queries derive outstanding debt and unapplied cash from the stored obligations, receipts and allocations.

**Postconditions:** Successful disbursement creates one loan and its schedule. Successful payment processing records one receipt and the applicable allocations. Surplus receipt value remains unapplied and is calculated from those records.

**Alternative and exception paths:**

- A credit officer may reject a submitted application with a reason instead of approving it.
- Approval rejects pending or rejected KYC, KYC belonging to another borrower, inactive products or amounts outside product limits.
- Disbursement rejects unapproved applications and a second loan for the same application.
- An exact payment retry returns the existing receipt without additional allocations.
- A split payment can complete one instalment and partially pay the next.
- Overpayment leaves unapplied cash; a refund or treasury case-management workflow is not implemented.
- A failing statement within a procedure transaction rolls back its work. Sequence numbers can still have gaps.

## Data model

Eight tables separate identity, verification, commercial product definitions, applications, disbursed contracts, scheduled obligations, receipts and allocation records. See the [README](README.md) for the entity table and [ER diagram](er-diagram.png), and [normalisation.md](normalisation.md) for the decomposition.

A repayment belongs to one loan and can have allocations to several instalments of that loan. Each instalment can receive allocations from several repayments. The junction key `(repayment_id, instalment_id)` permits one allocation row per pairing.

A supporting KYC link is optional on a submitted or rejected application and required on an approved application. A single verified submission may support multiple approvals; the foreign key is not unique.

## Business rules and enforcement

### Declarative integrity

| Rule | Supplied enforcement |
|---|---|
| Email is required, unique, lowercase and matches the selected pattern | NOT NULL, UNIQUE and CHECK constraints; uppercase input is rejected, not automatically converted |
| Phone is required, unique and has an optional plus sign followed by 10 to 15 digits | NOT NULL, UNIQUE and regex CHECK; this is a format check, not complete E.164 validation or real-number verification |
| KYC status is PENDING, VERIFIED or REJECTED | Status CHECK |
| Pending KYC has no decision time; decided KYC requires one; decision cannot precede submission | Lifecycle and chronology CHECK constraints |
| Product minimum is positive, maximum is at least minimum, term is 1 to 12 months and rate is nonnegative | Product CHECK constraints |
| Application principal is positive; state and decision fields agree; chronology is valid | Application CHECK constraints |
| A loan has one application and at most one loan exists per application; references are unique | Foreign key and UNIQUE constraints |
| Instalment numbers are positive and unique within a loan; due amounts are nonnegative and combined due is positive | Composite UNIQUE and CHECK constraints |
| Repayment amount is positive; provider reference and idempotency key are unique | CHECK and UNIQUE constraints |
| Allocation pairs are unique and amounts are positive | Composite primary key and CHECK |
| Referenced parents cannot be deleted while children depend on them | Restrictive foreign keys |

Unique email and phone values do not by themselves establish a unique human identity. Phone formatting variants are not automatically canonicalised by the schema.

### Workflow and multirow integrity

| Rule | Supplied enforcement and boundary |
|---|---|
| Approval must use verified KYC belonging to the applicant and satisfy active product limits | Approval procedure; it locks the application row, but not every related KYC or product row |
| Disbursement requires approval and prevents duplicate loans | Disbursement procedure and unique application constraint |
| Contract principal, rate, term and application linkage remain fixed after disbursement | Contract update guard; other loan attributes are not all protected |
| A loan and its complete schedule are created together with exact rounded totals | Disbursement procedure; final instalment absorbs the residual |
| Receipt and allocated instalment must belong to the same loan | Allocation trigger |
| Allocations must not exceed receipt value or instalment due | Trigger checks aggregate totals; procedure serialises payment calls on the loan row |
| Retried matching payment must not duplicate receipts or allocations | Unique identifiers and the repayment procedure; tested using an exact retry |
| Unapplied cash is receipt value minus its allocations | Derived reporting and procedure output; there is no separate cash account or treasury alert table |

Controlled procedure use is part of the intended design. Direct table writes can bypass some workflow checks. The supplied code does not comprehensively prevent edits and deletes of payment history. Concurrent direct writes need additional locking and permissions; they are not certified by the single-session test results.

## Worked financial example

A synthetic borrower obtains NGN 300000 for three months at a 6% full-term flat rate. Interest is NGN 18000 and the three instalments are NGN 106000 each.

| Event | Receipt NGN | Allocation | Debt remaining NGN | Unapplied receipt value NGN |
|---|---|---|---|---|
| Disbursement | 0 | Three scheduled dues totalling 318000 | 318000 | 0 |
| Payment 1 | 120000 | 106000 to instalment 1; 14000 to instalment 2 | 198000 | 0 |
| Payment 2 | 92000 | Remaining 92000 to instalment 2 | 106000 | 0 |
| Payment 3 | 150000 | 106000 to instalment 3 | 0 | 44000 |
| Exact retry of payment 1 | No new receipt | No new allocation | 0 | 44000 |

The corrected test suite checked this example, complete schedule creation, exact retry behaviour and independent totals. It reported 30 passed checks and no failures, then rolled its isolated test records back.

## Technical choices and later portfolios

PostgreSQL supplies foreign keys, exact numeric types, generated totals, transactions and row locks. Views derive balances without maintaining a second mutable balance column. A complete double-entry ledger, immutable audit trail, independent bank reconciliation and comprehensive access controls would require additional design.

Portfolio 2 can evaluate realistic query plans and indexing. Portfolio 3 can use two sessions to test locking and retries. Portfolio 4 can model synthetic document metadata or variable assessment records in MongoDB while retaining PostgreSQL financial records. Portfolio 5 can use Docker Compose for separate services and recovery exercises; containerisation alone does not demonstrate database distribution or replication. These later exercises are proposed, not completed.

## Limitations and submission evidence

This is an academic lending and allocation model. The 30 checks demonstrate specified cases, not every input, concurrency schedule or administrative mutation. Reconciliation views should be assessed against independently derived totals; repeating the same expression in expected and calculated columns does not independently verify an invariant.

Use the [README evidence list](README.md#evidence) and saved CSV to document the work performed. Do not claim live integrations, complete immutability, production security, regulatory compliance or verified Git history without additional evidence. The AI use declaration in the README applies to this case study and the related documentation.
