defmodule BilimbiWeb.SupplyChainSuppliersLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures

  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"

  setup do
    signed_in_identity!()
    TestFixtures.create_purchasing_tables!()
    :ok
  end

  test "the page needs authentication and the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/supply-chain/suppliers")

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/supply-chain/suppliers")
  end

  test "a configurer adds a supplier and a tax code and deactivates the supplier", %{conn: conn} do
    grant_capabilities!([@view, @configure])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/supply-chain/suppliers")
    assert has_element?(view, "#suppliers-table-empty", "No suppliers yet")

    view
    |> form("#supplier-form",
      supplier: %{
        code: "acme-parts",
        name: "Acme Parts",
        email: "orders@example.test",
        country_iso: "zz"
      }
    )
    |> render_submit()

    assert has_element?(view, "#suppliers-table td", "acme-parts")
    assert render(view) =~ "Supplier acme-parts added."

    view
    |> form("#tax-code-form", tax_code: %{code: "std", name: "Standard", rate: "8"})
    |> render_submit()

    assert has_element?(view, "#tax-codes-table td", "std")

    {:ok, scope} = Tenancy.scope(41)
    {:ok, [supplier]} = Purchasing.list_suppliers(TestFixtures.sign_in!(scope, 73, 91, []), 73)

    view |> element("#supplier-toggle-#{supplier.id}") |> render_click()
    assert has_element?(view, "#suppliers-table td", "Inactive")

    assert view
           |> form("#supplier-form", supplier: %{code: "acme-parts", name: "Again"})
           |> render_submit() =~
             "has already been taken"
  end

  test "a viewer sees the lists but no editor, and a forged write is refused", %{conn: conn} do
    grant_capabilities!([@view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/supply-chain/suppliers")

    refute has_element?(view, "#supplier-form")
    refute has_element?(view, "#tax-code-form")

    assert render_hook(view, "save_supplier", %{"supplier" => %{"code" => "x", "name" => "X"}}) =~
             "permission to configure purchasing"

    {:ok, scope} = Tenancy.scope(41)
    assert {:ok, []} = Purchasing.list_suppliers(TestFixtures.sign_in!(scope, 73, 91, []), 73)
  end
end
