[
  id: "supply_chain/purchasing",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_supply_chain_purchasing,
  namespace: Bilimbi.SupplyChain.Purchasing,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_012_210_000 => :bilimbi_only,
    20_261_013_100_000 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.SupplyChain.Purchasing.Contributions,
  dev_seed: nil
]
