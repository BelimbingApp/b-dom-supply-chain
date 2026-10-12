# b-dom-supply-chain

Supply Chain Domain for [Bilimbi](https://github.com/BelimbingApp/bilimbi):
buying through to delivery. It is one optional, independently versioned
repository that an adopter mounts into a Bilimbi checkout; it does not build
on its own.

| Module | Descriptor ID | Owns |
| --- | --- | --- |
| [`purchasing/`](purchasing/docs/README.md) | `supply_chain/purchasing` | each company's suppliers, tax codes, purchase requests, and purchase orders with lines, approval, amendments, and an audited status history |

Purchasing is the first module. Later Supply Chain modules sit beside it as
sibling module folders: receiving (goods against a purchase order, matched
with the supplier's bill in Finance), supplier price lists, sourcing, demand
planning, and logistics. Each of them, and other Domains such as Finance
payables, reads purchase orders through `Bilimbi.SupplyChain.Purchasing`'s
facade; none reads its tables. Inventory stays in the Factory Domain, and
Purchasing works for a trading company that does not mount Factory: a
purchase order line names its item as a description, with an optional
external item reference the company may point at any catalogue.

## Mount

Clone this repository into a Bilimbi checkout at
`apps/domains/supply_chain`, then work from the Bilimbi root:

```sh
git clone https://github.com/BelimbingApp/b-dom-supply-chain.git apps/domains/supply_chain
mix deps.get
mix bilimbi.migrate
mix precommit
```

Bilimbi discovers the mounted container from `bilimbi.container.exs`; no list
names it. Removing the directory removes Supply Chain's code from the next
build and keeps its data. The composition rules, including the shared
composition lock, are in Bilimbi's
[composition model](https://github.com/BelimbingApp/bilimbi/blob/main/docs/architecture/0010_composition-model.md).

After migrating, the Supply chain menu offers Purchase requests, Purchase
orders, and Suppliers to accounts holding the purchasing capabilities; the
Tenant Owner role holds them all.

## Naming

Optional Bilimbi repositories are named `b-<role>-<id>`: `b-` for Bilimbi,
`dom-` for a Domain. The mount folder is the container ID, with hyphens as
underscores, so `b-dom-supply-chain` mounts at `apps/domains/supply_chain`.

## CI

CI checks out Bilimbi at the revision in
[`.github/bilimbi-revision`](.github/bilimbi-revision), mounts this
repository, and runs Bilimbi's precommit over the composed workspace. Bump that
revision to build against a newer Platform. A second job runs the same
precommit with Supply Chain absent, and
[`missing_dependency.sh`](.github/scripts/missing_dependency.sh) proves a
mounted dependent without Supply Chain fails composition.

## License

[MIT](LICENSE).
