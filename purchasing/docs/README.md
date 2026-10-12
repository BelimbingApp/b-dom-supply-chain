# Purchasing

Module ID: `supply_chain/purchasing`. A company's suppliers and tax codes,
its purchase requests, and its purchase orders with lines, approval,
amendments, receipts, and an audited status history. Other Supply Chain
modules and other Domains read and write through this module's facade; none
of them reads its tables.

## Public API

Call `Bilimbi.SupplyChain.Purchasing` with a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit company ID. Results are plain
maps; the schemas are private. Attributes take atom or string keys.

| Function | Capability | Does |
| --- | --- | --- |
| `list_suppliers/3`, `get_supplier/3` | `supply-chain.purchasing.view` | The company's suppliers by code; `active: true` keeps active ones |
| `create_supplier/3`, `update_supplier/4` | `supply-chain.purchasing.configuration.manage` | Adds a supplier (`code`, `name`, contact and address facts) or changes its details or `active` flag |
| `list_tax_codes/3`, `create_tax_code/3`, `update_tax_code/4` | view / configuration.manage | A company's tax codes: `code`, `name`, `rate` (a percentage), `active` |
| `list_requests/3`, `get_request/3` | `supply-chain.purchasing.view` | Purchase requests with lines; `get_request/3` adds the status history |
| `create_request/3`, `update_request/4` | `supply-chain.purchasing.requests.manage` | A draft request: `title`, `justification`, `needed_on`, `lines` |
| `submit_request/3`, `cancel_request/4` | `supply-chain.purchasing.requests.manage` | Submits a draft; cancels a draft, submitted, or approved request with a `reason` |
| `approve_request/4`, `reject_request/4` | `supply-chain.purchasing.requests.approve` | Decides a submitted request; rejection needs a `reason` |
| `create_order_from_request/4` | `supply-chain.purchasing.orders.manage` | Drafts an order from an approved request, copying its lines unpriced unless `lines` is given |
| `list_orders/3`, `get_order/3`, `find_order_by_number/3` | `supply-chain.purchasing.view` | Orders with current lines and totals; the single reads add history and amendments |
| `get_order_line/3` | `supply-chain.purchasing.view` | One line, current or superseded, with its order's number, status, supplier, and currency |
| `create_order/3`, `update_order/4` | `supply-chain.purchasing.orders.manage` | A draft order: `supplier_id`, `currency_code`, `reference`, `notes`, `expected_on`, `lines` |
| `submit_order/3`, `send_order/3`, `close_order/4`, `cancel_order/4` | `supply-chain.purchasing.orders.manage` | The buyer's transitions; closing and cancelling need a `reason`, and cancelling after approval also needs the approver's capability |
| `approve_order/4`, `return_order/4` | `supply-chain.purchasing.orders.approve` | Approves a submitted order, or returns it to draft with a `reason` |
| `amend_order/4` | `supply-chain.purchasing.orders.manage` | Records an amendment (`reason`, `lines`, optional header facts) on an approved or sent order |
| `record_receipt/4` | `supply-chain.purchasing.orders.receive` | Adds received quantities to a sent order's lines |

## Authorization and company scope

Every call authorizes its capability for the scope's signed-in actor and the
target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`: the actor's own company,
or a sibling company with Core Company's tenant-wide reach. A system scope
names nobody and is `{:error, :unauthorized}`; a company the scope's tenant
cannot see is `{:error, :company_not_found}`. Writes then take
`Bilimbi.Core.Company.lock_writable_company/2` inside their transaction, so
an archived company is `{:error, :company_archived}` and one company's
purchasing writes run one at a time; that lock is also what keeps a
supplier from being deactivated while an order names it, and what makes
the gapless numbering safe. The Tenant Owner role holds every capability.

Approval is a separation of duties: the person who submitted a request or
order cannot approve it (`{:error, :own_request}` or `{:error, :own_order}`),
whatever they hold. Every write records who performed it from
`Scope.actor/1`, with the impersonator of an impersonated session; no
function takes an actor or actor ID.

## Suppliers and tax codes

A supplier is a party the company buys from: a `code` unique in the company
and fixed for good, a `name`, and optional contact and address facts
(`contact_name`, `email`, `phone`, `address_line1` to `address_line3`,
`locality`, `postcode`, `country_iso`, `admin1_code`) shaped like Core
Address so a later shared party record is a copy, not a translation. A
supplier is deactivated, never deleted: an inactive supplier takes no new
order, and its orders and history stay.

A tax code is a company's configuration: a `code`, a `name`, and a `rate`
in percent with up to four decimal places. An order line that names a tax
code snapshots its rate, so changing a rate affects future lines only. The
code ships no supplier, tax code, unit, or currency: all are a company's
data.

## Purchase requests

A request records what the company needs before an order is raised: a
`title`, optional `justification` and `needed_on`, and lines of
`description`, `quantity`, `unit`, and an optional `external_item_ref` (a
reference into any catalogue the company keeps; Purchasing does not
depend on one). The database numbers each company's requests 1, 2, 3, ...
on creation.

Statuses are `draft`, `submitted`, `approved`, `rejected`, and `cancelled`.
A draft is edited freely, lines included. Submission needs at least one
line and fixes the title, justification, date, and lines. A submitted
request is approved or rejected by someone other than its submitter;
rejection needs a reason the requester sees. A draft, submitted, or
approved request is cancelled with a reason. An approved request becomes a
draft order through `create_order_from_request/4`, which copies its lines
at a unit price of zero to be priced on the draft (or takes `lines`) and
records `purchase_request_id` on the order; a request may be ordered more
than once, for example from two suppliers.

## Purchase orders

An order names an active supplier and a currency (three upper-case
letters, a company's choice), carries optional `reference`, `notes`, and
`expected_on`, and has lines of `description`, optional
`external_item_ref`, `quantity`, `unit`, `unit_price`, and optional
`tax_code_id`. A line reports `line_total` and `tax_amount`, and the order
`subtotal`, `tax_total`, and `total`, all decimals in its currency; amounts
are `numeric(20, 4)` and are refused, not rounded, when finer. The database
numbers each company's orders 1, 2, 3, ... on creation, so a number is
never skipped or reused: a cancelled order keeps its number.

Statuses and transitions:

| From | To | Through |
| --- | --- | --- |
| `draft` | `submitted` | `submit_order/3`; needs a line and an active supplier |
| `draft` | `cancelled` | `cancel_order/4` |
| `submitted` | `approved` | `approve_order/4`, by someone else |
| `submitted` | `draft` | `return_order/4` with a reason |
| `submitted` | `cancelled` | `cancel_order/4` |
| `approved` | `sent` | `send_order/3` |
| `approved` | `cancelled` | `cancel_order/4`, also needing the approver's capability |
| `sent` | `partially_received` | `record_receipt/4` |
| `sent`, `partially_received` | `closed` | `close_order/4` with a reason, or `record_receipt/4` once every line is received in full |
| `sent`, `partially_received` | `cancelled` | `cancel_order/4`, also needing the approver's capability |

`closed` and `cancelled` are final. Every creation and transition writes a
history row: the previous and new status, the actor and any impersonator,
the reason given, and the time the database recorded it.

A draft changes freely. From submission on, the supplier, currency, and
request link are fixed, and the header and lines change only as follows:

- **Amendments.** An approved or sent order changes only through
  `amend_order/4`, which records an amendment (a per-order number, the
  reason, the actor, the time), applies any `reference`, `notes`, or
  `expected_on` given, and replaces the current lines with the given ones.
  The replaced lines stay on the order marked `superseded_by_amendment_id`,
  so `get_order/3` shows the current lines and each amendment with the
  lines it added and the IDs of those it replaced, and `get_order_line/3`
  still reads a superseded line. A partially received order is not amended;
  it is closed short or cancelled.
- **Receipts.** A sent or partially received order's lines take received
  quantities through `record_receipt/4`, each receipt adding to a current
  line's `received_quantity`, which never exceeds the ordered one.

## Seams for later modules

- **Receiving** (goods against an order, matched with the supplier's bill
  in Finance) calls `record_receipt/4` under
  `supply-chain.purchasing.orders.receive` and keeps the goods receipt as its
  own record; Purchasing holds only each line's received quantity.
- **Finance payables** matches a bill line to an order line through
  `get_order_line/3` and `find_order_by_number/3`; the line carries the
  order's number, status, supplier, and currency, its quantity, unit price,
  tax rate, and received quantity. Purchasing posts nothing to the ledger
  and depends on neither Finance nor Factory.
- **Factory** inventory, when mounted, is reached through a line's
  `external_item_ref`, a free reference the company fills from any
  catalogue; Purchasing never resolves it.

## Database

The migration `20261012210000` is `:bilimbi_only` and creates
`supply_chain_purchasing_suppliers`, `_tax_codes`, `_requests`,
`_request_lines`, `_request_events`, `_orders`, `_order_amendments`,
`_order_lines`, and `_order_events`. PostgreSQL enforces the rules the
facade checks, so no other writer can break them:

- composite `(id, company_id)` foreign keys keep an order's supplier, tax
  code, request, lines, amendments, and history in one company, and a
  line's amendment in its own order;
- triggers refuse DELETE and TRUNCATE on every table, UPDATE on history
  rows and amendments, and changing a supplier's or tax code's company or
  code;
- triggers number each company's requests and orders, and each order's
  amendments, without gaps, and stamp history rows and amendments;
- a trigger allows only the transitions in the table above, refuses any
  other header change after draft except an amendment that raises
  `amendment_count` by one, and freezes lines after draft except an
  amendment's additions and supersessions and a receipt's received quantity;
- deferred constraint triggers refuse a commit in which a request or order
  was created or changed status without a history row written in the same
  transaction, or counted an amendment without its record.

`Bilimbi.SupplyChain.Purchasing.SchemaContract` describes the tables but is
not registered in the descriptor: compatibility verification runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.
`test/schema_contract_test.exs` runs the migration in a fresh database,
verifies the contract with `Bilimbi.Base.Database.SchemaVerifier.verify/2`,
and proves the migration's own triggers outside the test sandbox.

## Standards addressed

- **Audit trail.** Every request and order records who created it, and every
  transition records its actor (and any impersonator), the database's
  timestamp, and the reason; the database refuses a transition without one.
  Amendments name who changed an approved order, when, why, and what the
  lines were before. Every write also goes through `Bilimbi.Base.Repo`,
  which Base Audit records with its actor in the composed host.
- **Immutability.** An approved order is fixed except through an amendment
  record; nothing posted is edited in place.
- **Retention.** Nothing is deleted: the database refuses DELETE and
  TRUNCATE, suppliers and tax codes are deactivated, and unmounting Supply
  Chain keeps every row.
- **Gapless numbering.** Each company's requests and orders are numbered in
  creation order without gaps; a refused or rolled-back creation takes none.
- **Separation of duties.** An approver is not the submitter.

## Pages and menu

The Supply chain menu offers three pages to accounts holding
`supply-chain.purchasing.view`, each acting on the signed-in company:

- **Suppliers** (`/supply-chain/suppliers`): the suppliers and tax codes,
  with forms to add either and controls to deactivate them for accounts
  holding the configuration capability.
- **Purchase requests** (`/supply-chain/purchase-requests`): the requests by
  status, a form that drafts one with up to five lines, and per-row submit,
  decide, cancel, and create-order actions under their capabilities.
- **Purchase orders** (`/supply-chain/purchase-orders`): the orders by
  status and a form that drafts one with up to five lines; each order's
  page (`/supply-chain/purchase-orders/:id`) shows its lines, totals,
  history, and amendments, and offers the transitions its status allows.

Irreversible actions wait for confirmation. A page refuses a write-shaped
event it does not offer, and the facade checks the capability again when
the event runs. Amendments and receipts have no page yet; callers use the
facade.

## Tests

Module tests run on temporary copies of the tables built from the
migration's own `statements(:temporary)` in
`test/support/test_fixtures.ex`, constraints and triggers included, so the
tables cannot drift from the migration. `setup_purchasing!/0` there builds
two tenants' companies and an Authz snapshot, and `sign_in!/4` signs a user
in with direct grants. `web_test/` runs the three pages against the real
host.
