defmodule Bilimbi.SupplyChain.Purchasing.SuppliersTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"

  setup do
    context = TestFixtures.setup_purchasing!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, [@view, @configure])
    Map.put(context, :operator, operator)
  end

  describe "suppliers" do
    test "are created with their contact and address and listed by code", %{operator: operator} do
      assert {:ok, supplier} =
               Purchasing.create_supplier(
                 operator,
                 73,
                 TestFixtures.supplier_attributes(%{
                   code: "b-sup",
                   name: " Second ",
                   country_iso: "zz"
                 })
               )

      assert %{code: "b-sup", name: "Second", country_iso: "ZZ", active: true} = supplier

      {:ok, _} =
        Purchasing.create_supplier(
          operator,
          73,
          TestFixtures.supplier_attributes(%{code: "a-sup"})
        )

      assert {:ok, [%{code: "a-sup"}, %{code: "b-sup"}]} = Purchasing.list_suppliers(operator, 73)
      assert {:ok, ^supplier} = Purchasing.get_supplier(operator, 73, supplier.id)
    end

    test "accept string keys and refuse a bad code, email, or country", %{operator: operator} do
      assert {:ok, %{code: "s1"}} =
               Purchasing.create_supplier(operator, 73, %{"code" => "s1", "name" => "One"})

      assert {:error, changeset} =
               Purchasing.create_supplier(operator, 73, %{
                 code: "s1",
                 name: "Again",
                 email: "not-an-email",
                 country_iso: "zzz"
               })

      assert %{email: [_], country_iso: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Purchasing.create_supplier(operator, 73, %{code: "s1", name: "Again"})

      assert %{code: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} = Purchasing.create_supplier(operator, 73, %{code: "", name: ""})
      assert %{code: ["can't be blank"], name: ["can't be blank"]} = errors_on(changeset)
    end

    test "keep their code and are deactivated, never deleted", %{operator: operator} do
      {:ok, supplier} =
        Purchasing.create_supplier(
          operator,
          73,
          TestFixtures.supplier_attributes(%{code: "keep"})
        )

      assert {:ok, %{code: "keep", name: "Renamed", active: false}} =
               Purchasing.update_supplier(operator, 73, supplier.id, %{
                 code: "changed",
                 name: "Renamed",
                 active: false
               })

      assert {:ok, []} = Purchasing.list_suppliers(operator, 73, active: true)
      assert {:ok, [_]} = Purchasing.list_suppliers(operator, 73)

      assert_raise Postgrex.Error, ~r/supply chain purchasing keeps/, fn ->
        SQL.query!(Repo, "DELETE FROM supply_chain_purchasing_suppliers", [])
      end

      assert_raise Postgrex.Error, ~r/keeps its company and code/, fn ->
        SQL.query!(Repo, "UPDATE supply_chain_purchasing_suppliers SET code = 'x'", [])
      end

      assert {:error, :supplier_not_found} =
               Purchasing.update_supplier(operator, 73, supplier.id + 1, %{name: "x"})
    end

    test "belong to one company and need the grant", %{first_scope: system, operator: operator} do
      {:ok, supplier} =
        Purchasing.create_supplier(
          operator,
          73,
          TestFixtures.supplier_attributes(%{code: "mine"})
        )

      sibling = TestFixtures.sign_in!(system, 74, 92, [@view, @configure])
      assert {:ok, []} = Purchasing.list_suppliers(sibling, 74)
      assert {:error, :supplier_not_found} = Purchasing.get_supplier(sibling, 74, supplier.id)
      assert {:error, :unauthorized} = Purchasing.list_suppliers(sibling, 73)

      viewer = TestFixtures.sign_in!(system, 73, 93, [@view])
      assert {:ok, [_]} = Purchasing.list_suppliers(viewer, 73)

      assert {:error, :unauthorized} =
               Purchasing.create_supplier(viewer, 73, TestFixtures.supplier_attributes())

      assert {:error, :unauthorized} = Purchasing.list_suppliers(system, 73)
      assert {:error, :company_not_found} = Purchasing.list_suppliers(operator, 75)

      TestFixtures.revoke!(system, 73, 91, @configure)

      assert {:error, :unauthorized} =
               Purchasing.update_supplier(operator, 73, supplier.id, %{name: "x"})
    end
  end

  describe "tax codes" do
    test "are created with a rate, listed by code, and keep their code", %{operator: operator} do
      assert {:ok, tax_code} =
               Purchasing.create_tax_code(operator, 73, %{
                 code: "std",
                 name: "Standard",
                 rate: "6.5"
               })

      assert Decimal.equal?(tax_code.rate, "6.5")

      assert {:error, changeset} =
               Purchasing.create_tax_code(operator, 73, %{
                 code: "bad",
                 name: "Bad",
                 rate: "100.00001"
               })

      assert %{rate: [_ | _]} = errors_on(changeset)

      assert {:error, changeset} =
               Purchasing.create_tax_code(operator, 73, %{code: "std", name: "Again", rate: "1"})

      assert %{code: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, %{code: "std", active: false}} =
               Purchasing.update_tax_code(operator, 73, tax_code.id, %{code: "x", active: false})

      assert {:ok, []} = Purchasing.list_tax_codes(operator, 73, active: true)
      assert {:ok, [%{code: "std"}]} = Purchasing.list_tax_codes(operator, 73)
      assert {:error, :tax_code_not_found} = Purchasing.update_tax_code(operator, 73, 0, %{})
    end
  end
end
