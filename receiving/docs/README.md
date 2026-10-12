# Receiving

Module ID: `supply_chain/receiving`. A company's goods receipts against its
purchase orders: what arrived, what was accepted and what was rejected and
why, posted so the order's received quantities follow and a supplier's bill
in Finance can be matched to what was ordered and received. Orders are read
and changed only through `Bilimbi.SupplyChain.Purchasing`'s facade; this
module never reads Purchasing's tables, and other modules never read its.

## Public API

Call `Bilimbi.SupplyChain.Receiving` with a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit company ID. Results are plain
maps; the schemas are private. Attributes take atom or string keys.

| Function | Capability | Does |
| --- | --- | --- |
| `get_settings/2` | `supply-chain.receiving.view` | The company's over-receipt tolerance (zero until set), who set it and when |
| `configure/3` | `supply-chain.receiving.configuration.manage` | Sets `over_receipt_tolerance_percent` (0 to 100); each change is a new row, the history stays |
| `list_receipts/3`, `get_receipt/3`, `find_receipt_by_number/3` | `supply-chain.receiving.view` | Receipts with lines, by `status`, `order_id`, `limit`; the single reads add history and the reversal links |
| `create_receipt/3`, `update_receipt/4` | `supply-chain.receiving.receipts.manage` | A draft against a sent or partially received order: `order_id`, `received_on`, `supplier_reference`, `notes`, `lines` |
| `cancel_receipt/4` | `supply-chain.receiving.receipts.manage` | Cancels a draft with a `reason`; it keeps its number |
| `post_receipt/3` | `supply-chain.receiving.receipts.post` | Posts a draft: records the accepted quantities on the order, fixes the receipt |
| `reverse_receipt/4` | `supply-chain.receiving.receipts.post` | Posts a reversal of a posted receipt with a `reason`, taking the goods back off the order |
| `order_receipts/3`, `order_line_receipts/3` | `supply-chain.receiving.view` | Net received and rejected quantities per order line from posted receipts, for three-way matching |
| `list_postings/3` | `supply-chain.receiving.view` | Postings in order, each read once by `after_posting_id`; the stock seam |

## Authorization and company scope

Every call authorizes its capability for the scope's signed-in actor and the
target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`, and writes take
`Bilimbi.Core.Company.lock_writable_company/2` inside their transaction, as
Purchasing does. Every write records who performed it from `Scope.actor/1`,
with the impersonator of an impersonated session; no function takes an
actor or actor ID.

Orders are read through Purchasing's facade with the same scope, so an
actor who drafts a receipt also holds `supply-chain.purchasing.view`, and
one who posts or reverses also holds
`supply-chain.purchasing.orders.receive`; Purchasing refuses the posting
otherwise and the receipt stays a draft. The Tenant Owner role holds every
capability of both modules.

## Goods receipts

A receipt names a purchase order that is `sent` or `partially_received` (an
order in any other status is `{:error, {:order_not_receivable, status}}`),
the date the goods were received (`received_on`, default today), the
supplier's delivery reference, and notes. Its lines each name one current
line of the order by `order_line_id`, with the accepted quantity
(`received_quantity`) and the rejected quantity (`rejected_quantity`, which
carries its `rejection_reason`); a line has at least one of the two, and a
receipt names each order line once. Each line copies the order line's
number, description, unit, and ordered quantity when it is written and again
when it is posted, so a receipt reads the same whatever the order becomes.
The database numbers each company's receipts 1, 2, 3, ... on creation, so
a number is never skipped or reused: a cancelled draft keeps its number.

Statuses and transitions:

| From | To | Through |
| --- | --- | --- |
| `draft` | `posted` | `post_receipt/3`, or `reverse_receipt/4` for the reversal it creates |
| `draft` | `cancelled` | `cancel_receipt/4` with a reason |

`posted` and `cancelled` are final. Every creation and transition writes a
history row: the previous and new status, the actor and any impersonator,
the reason given, and the time the database recorded it.

- **Posting.** `post_receipt/3` records the accepted quantities on the order
  through `Purchasing.record_receipt/4`, passing the company's tolerance:
  the order becomes partially received, or closes when every line is in.
  Rejected goods count on nothing; a receipt that accepted nothing still
  posts, as the record of the rejection. A line the order no longer carries
  (amended away while the receipt was a draft) refuses the posting; the
  draft is corrected or cancelled.
- **Over-receipt.** A line's accepted quantity, added to what the order line
  already received, may not exceed the ordered quantity by more than the
  company's `over_receipt_tolerance_percent`. The draft refuses it up front
  against the tolerance of the moment, and Purchasing refuses it again at
  posting against the tolerance passed then, so a tolerance lowered after
  drafting still applies.
- **Reversals.** A posted receipt is never edited. `reverse_receipt/4`
  creates and posts, in one transaction, a receipt of kind `reversal` that
  names the original (`reverses_receipt_id`), copies its lines, carries the
  reason, and takes the accepted quantities back off the order through
  `Purchasing.reverse_receipt/4`, which reopens a closed order as partially
  received. A receipt is reversed once; a reversal is not reversed: the
  goods are received again with a new receipt. `get_receipt/3` shows both
  links as `reverses_receipt_number` and `reversed_by_receipt_number`.

## Seams for other modules

- **Finance payables** (three-way matching) reads the ordered facts through
  `Purchasing.get_order_line/3` (quantity, unit price, tax rate, currency,
  supplier) and the received facts here through `order_line_receipts/3` or
  `order_receipts/3`: the net accepted `received_quantity`, the net
  `rejected_quantity`, and the posted receipts and reversals behind them,
  each with its number, date, and posting time. The billed quantity is
  Finance's own record; the match is Finance's code. Receiving posts
  nothing to the ledger and depends on neither Finance nor Factory.
- **Factory inventory** (stock movements), when mounted, consumes
  `list_postings/3`: every posting in the order it happened, each
  identified once by `posting_id`, a receipt adding its accepted lines to
  stock and a reversal taking them out, with each line's `order_line_id`
  and the order line's `external_item_ref` reachable through Purchasing.
  Postings are never edited or removed, so a consumer that keeps its last
  `posting_id` replays exactly once; a push notification can be added
  beside it without changing the record. Receiving holds no stock.

## Database

The migration `20261013110000` is `:bilimbi_only` and creates
`supply_chain_receiving_settings`, `_receipts`, `_receipt_lines`, and
`_receipt_events`. PostgreSQL enforces the rules the facade checks, so no
other writer can break them:

- composite `(id, company_id)` foreign keys keep a receipt's lines, history,
  and reversal in one company; the order and order lines are referenced by
  ID with their facts copied, never by a foreign key into Purchasing;
- triggers refuse DELETE and TRUNCATE on receipts, history rows, and
  settings, TRUNCATE on lines, and UPDATE on history rows and settings; a
  draft's lines are working data and may be replaced, while a posted or
  cancelled receipt's lines are fixed;
- a trigger numbers each company's receipts without gaps and makes a new
  receipt a draft; triggers stamp history rows and settings;
- a trigger allows only the transitions in the table above and refuses any
  other change to a posted or cancelled receipt, and another freezes its
  lines; a partial unique index lets a posted receipt be reversed once;
- a deferred constraint trigger refuses a commit in which a receipt was
  created or changed status without a history row written in the same
  transaction.

Purchasing's migration `20261013100000` is what lets a reversal reopen a
closed order and lets a line's received quantity exceed the ordered one
within the tolerance.

`Bilimbi.SupplyChain.Receiving.SchemaContract` describes the tables but is
not registered in the descriptor: compatibility verification runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.
`test/schema_contract_test.exs` runs the migration in a fresh database,
verifies the contract with `Bilimbi.Base.Database.SchemaVerifier.verify/2`,
and proves the migration's own triggers outside the test sandbox.

## Standards addressed

- **Audit trail.** Every receipt records who created it and who posted it,
  and every transition records its actor (and any impersonator), the
  database's timestamp, and the reason; the database refuses a transition
  without one. Every write also goes through `Bilimbi.Base.Repo`, which
  Base Audit records with its actor in the composed host.
- **Immutability.** A posted receipt and its lines never change; a mistake
  is corrected by a reversal receipt that names it and carries its reason.
- **Retention.** Nothing posted is deleted: the database refuses DELETE and
  TRUNCATE on receipts, history, and settings, and any change to the lines of
  a posted or cancelled receipt. A draft's lines are working data and may be
  replaced until it is posted; a draft is cancelled, never deleted, settings
  changes are appended, and unmounting Supply Chain keeps every row.
- **Gapless numbering.** Each company's receipts are numbered in creation
  order without gaps; a refused or rolled-back creation takes none.
- **Reproducible reports.** A posted receipt carries the order line's
  description, unit, and ordered quantity as they were at posting, and the
  net quantities per order line are sums over posted rows that never change,
  so a matching report reads the same later.

## Pages and menu

The Supply chain menu offers **Goods receipts** (`/supply-chain/receipts`)
to accounts holding `supply-chain.receiving.view`, acting on the signed-in
company: the receipts by status, the over-receipt tolerance form for
accounts holding the configuration capability, and the way to **Receive
goods** (`/supply-chain/receive`), where an account holding the receipts
capability picks a sent order and enters accepted and rejected quantities
per line to save a draft. Each receipt's page (`/supply-chain/receipts/:id`)
shows its lines and history and offers post, cancel, and reverse under
their capabilities. Irreversible actions wait for confirmation. A page
reads the capability again for every write-shaped event and refuses one
its action does not allow, and the facade checks the capability again when
the event runs.

## Tests

Module tests run on temporary copies of the tables built from the
migration's own `statements(:temporary)` in
`test/support/test_fixtures.ex`, constraints and triggers included, with
Purchasing's tables from Purchasing's fixture the same way, so neither can
drift from its migration. `setup_receiving!/0` there builds two tenants'
companies and an Authz snapshot over both modules, `sign_in!/4` signs a
user in with direct grants, and `sent_order!/4` raises a sent order through
Purchasing's facade. `web_test/` runs the three pages against the real host.
