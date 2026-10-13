defmodule Bilimbi.SupplyChain.Purchasing.TestFixtures do
  @moduledoc """
  Purchasing tables, authorization, and two tenants' companies for module
  tests.

  The tables are temporary copies of the migrations', constraints and
  triggers included, built from the same `statements/1` each migration
  runs, so a test that makes PostgreSQL refuse proves a migration's rule and
  the two cannot drift. `test/schema_contract_test.exs` checks the real
  migrations against the schema contract in a fresh database.
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
  alias Ecto.Adapters.SQL

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"
  @manage_requests "supply-chain.purchasing.requests.manage"
  @approve_requests "supply-chain.purchasing.requests.approve"
  @manage_orders "supply-chain.purchasing.orders.manage"
  @approve_orders "supply-chain.purchasing.orders.approve"
  @receive_orders "supply-chain.purchasing.orders.receive"

  @doc "Every purchasing capability, as a test grants them all at once."
  def all_capabilities do
    [
      @view,
      @configure,
      @manage_requests,
      @approve_requests,
      @manage_orders,
      @approve_orders,
      @receive_orders
    ]
  end

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  purchasing and Authz tables, and an Authz snapshot that knows the
  purchasing capabilities. Returns the two tenants' system scopes.
  """
  def setup_purchasing! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    create_purchasing_tables!()
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

  @doc "An Authz snapshot over the platform's and purchasing's capabilities."
  def install_authz! do
    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"supply_chain/purchasing", :bilimbi_supply_chain_purchasing,
             Purchasing.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    ContributionRegistry.put_consumers_for_test!(
      %{authz: ContributionValidator.validate_contributions!(entries)},
      "supply-chain-purchasing-test"
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

  @doc """
  Temporary copies of the tables, constraints, and triggers, as every
  migration leaves them in version order.
  """
  def create_purchasing_tables! do
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
    for {version, module} <- Purchasing.SchemaContract.migrations() do
      [file] = Path.wildcard(Path.join(@migrations_path, "#{version}_*.exs"))
      Code.require_file(file)
      module
    end
  end

  @doc "A supplier of the company, with any attribute overridden."
  def supplier_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        code: "sup-#{System.unique_integer([:positive])}",
        name: "A supplier",
        contact_name: "A contact",
        email: "contact@example.test",
        phone: "+00 000",
        address_line1: "1 Example Street",
        locality: "Example Town",
        postcode: "00000",
        country_iso: "zz"
      },
      overrides
    )
  end

  @doc "One order or request line, with any attribute overridden."
  def line(overrides \\ %{}) do
    Map.merge(
      %{description: "An item", quantity: "10", unit: "unit", unit_price: "2.50"},
      overrides
    )
  end
end
