[
  id: "supply_chain/receiving",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_supply_chain_receiving,
  namespace: Bilimbi.SupplyChain.Receiving,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "supply_chain/purchasing"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_261_013_110_000 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.SupplyChain.Receiving.Contributions,
  dev_seed: nil
]
