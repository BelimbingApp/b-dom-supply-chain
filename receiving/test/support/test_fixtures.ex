defmodule Bilimbi.SupplyChain.Receiving.TestFixtures do
  @moduledoc """
  Receiving tables, authorization, purchasing's tables, and two tenants'
  companies for module tests.

  The tables are temporary copies of the migration's, constraints and
  triggers included, built from the same `statements/1` the migration runs,
  so a test that makes PostgreSQL refuse proves the migration's rule and
  the two cannot drift. Purchasing's tables come from its own fixture the
  same way. `test/schema_contract_test.exs` checks the real migration
  against the schema contract in a fresh database.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures, as: PurchasingFixtures
  alias Bilimbi.SupplyChain.Receiving
  alias Ecto.Adapters.SQL

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @view "supply-chain.receiving.view"
  @configure "supply-chain.receiving.configuration.manage"
  @manage "supply-chain.receiving.receipts.manage"
  @post "supply-chain.receiving.receipts.post-receipt"

  @doc "Every receiving capability, as a test grants them all at once."
  def all_capabilities, do: [@view, @configure, @manage, @post]

  @doc """
  The purchasing capabilities a receiving actor also needs: to read orders,
  and to post or reverse against them.
  """
  def purchasing_capabilities,
    do: [Purchasing.view_capability(), Purchasing.receive_orders_capability()]

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  purchasing, receiving, and Authz tables, and an Authz snapshot that knows
  both modules' capabilities. Returns the two tenants' system scopes.
  """
  def setup_receiving! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    PurchasingFixtures.create_purchasing_tables!()
    create_receiving_tables!()
    install_authz!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first_company"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "other_tenant_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)
    %{first_scope: first, second_scope: second}
  end

  @doc "An Authz snapshot over the platform's, purchasing's, and receiving's capabilities."
  def install_authz! do
    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"supply_chain/purchasing", :bilimbi_supply_chain_purchasing,
             Purchasing.Contributions},
            {"supply_chain/receiving", :bilimbi_supply_chain_receiving, Receiving.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    ContributionRegistry.put_consumers_for_test!(
      %{authz: ContributionValidator.validate_contributions!(entries)},
      "supply-chain-receiving-test"
    )
  end

  @doc """
  A scope signed in as the user, after granting the capabilities directly
  in the company. Tests are the only module code that calls the edge.
  """
  def sign_in!(%Scope{} = scope, company_id, user_id, capabilities) do
    for capability <- capabilities do
      {:ok, :stored} =
        Authz.put_principal_capability(scope, company_id, :user, user_id, capability, true)
    end

    Authentication.sign_in(scope, user_id, company_id)
  end

  @doc "Denies one capability directly, which overrides any allow."
  def revoke!(%Scope{} = scope, company_id, user_id, capability) do
    {:ok, :stored} =
      Authz.put_principal_capability(scope, company_id, :user, user_id, capability, false)

    :ok
  end

  @doc "Makes PostgreSQL run the deferred history checks now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  @doc "Temporary copies of the migration's tables, constraints, and triggers."
  def create_receiving_tables! do
    for migration <- migrations(),
        statement <- apply(migration, :statements, [:temporary]),
        do: SQL.query!(Repo, statement, [])

    :ok
  end

  @doc """
  The migration modules in version order, as `SchemaContract.migrations/0`
  names them, loaded from their files. They are not compiled into the test
  build, so callers reach them with `apply/3`.
  """
  def migrations do
    for {version, module} <- Receiving.SchemaContract.migrations() do
      [file] = Path.wildcard(Path.join(@migrations_path, "#{version}_*.exs"))
      Code.require_file(file)
      module
    end
  end

  @doc """
  A sent purchase order of the company with the given lines (purchasing
  line attributes), as `Purchasing.get_order/3` returns it. `buyer` holds
  the purchasing configuration, orders.manage, and view capabilities, and
  `approver` orders.approve; the supplier is created on the first call.
  """
  def sent_order!(buyer, approver, company_id, lines) do
    supplier =
      case Purchasing.list_suppliers(buyer, company_id, active: true) do
        {:ok, [supplier | _rest]} ->
          supplier

        {:ok, []} ->
          {:ok, supplier} =
            Purchasing.create_supplier(
              buyer,
              company_id,
              PurchasingFixtures.supplier_attributes(%{code: "main"})
            )

          supplier
      end

    {:ok, order} =
      Purchasing.create_order(buyer, company_id, %{
        supplier_id: supplier.id,
        currency_code: "XTS",
        lines: lines
      })

    {:ok, _} = Purchasing.submit_order(buyer, company_id, order.id)
    {:ok, _} = Purchasing.approve_order(approver, company_id, order.id, %{})
    {:ok, order} = Purchasing.send_order(buyer, company_id, order.id)
    order
  end

  @doc "One receipt line against an order line, with any attribute overridden."
  def line(order_line, overrides \\ %{}) do
    Map.merge(%{order_line_id: order_line.id, received_quantity: "4"}, overrides)
  end
end
