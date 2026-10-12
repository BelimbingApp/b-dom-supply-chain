defmodule BilimbiWeb.SupplyChainOrdersLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures

  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"
  @manage "supply-chain.purchasing.orders.manage"
  @approve "supply-chain.purchasing.orders.approve"

  setup do
    signed_in_identity!()
    TestFixtures.create_purchasing_tables!()
    UserFixtures.insert_user!(%{id: 92, company_id: 73, email: "approver@example.test"})
    {:ok, scope} = Tenancy.scope(41)
    buyer = TestFixtures.sign_in!(scope, 73, 91, [@view, @configure, @manage])

    {:ok, supplier} =
      Purchasing.create_supplier(buyer, 73, TestFixtures.supplier_attributes(%{code: "s"}))

    {:ok, tax} =
      Purchasing.create_tax_code(buyer, 73, %{code: "std", name: "Standard", rate: "10"})

    %{scope: scope, buyer: buyer, supplier: supplier, tax: tax}
  end

  test "the pages need the view capability", %{conn: conn, scope: scope} do
    TestFixtures.revoke!(scope, 73, 91, @view)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders")

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/1")
  end

  test "a buyer drafts an order, submits it, an approver approves it, and the buyer sends it",
       %{conn: conn, buyer: buyer, supplier: supplier, tax: tax} do
    grant_capabilities!([@view, @approve], user_id: 92)
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders")
    assert has_element?(view, "#orders-table-empty", "No purchase orders here")

    view
    |> form("#order-form",
      order: %{
        supplier_id: supplier.id,
        currency_code: "xts",
        reference: "Q-7",
        lines: %{
          "0" => %{
            description: "Widget",
            quantity: "10",
            unit: "unit",
            unit_price: "2.5",
            tax_code_id: tax.id
          },
          "1" => %{description: ""}
        }
      }
    )
    |> render_submit()

    {:ok, [order]} = Purchasing.list_orders(buyer, 73)
    assert_redirect(view, ~p"/supply-chain/purchase-orders/#{order.id}")
    assert %{status: "draft", currency_code: "XTS", lines: [%{tax_rate: rate}]} = order
    assert Decimal.equal?(rate, "10")

    {:ok, show, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/#{order.id}")

    assert has_element?(show, "#order-lines-table td", "Widget")
    assert has_element?(show, "#order-facts", "27.5")
    assert has_element?(show, "#order-events li", "Draft")

    show |> element("#order-submit") |> render_click()
    show |> element("#order-confirm button", "Submit") |> render_click()
    assert render(show) =~ "submitted for approval"
    assert has_element?(show, "#order-events li", "Submitted")
    refute has_element?(show, "#order-decide")

    {:ok, approval, _html} =
      conn
      |> log_in_as(session_user(%{"user_id" => 92}))
      |> live(~p"/supply-chain/purchase-orders/#{order.id}")

    approval
    |> form("#order-decide", %{reason: "Within budget"})
    |> render_submit(%{"action" => "approve"})

    approval |> element("#order-confirm button", "Approve") |> render_click()
    assert render(approval) =~ "Order approved."

    assert {:ok, %{status: "approved", approved_by_user_id: 92}} =
             Purchasing.get_order(buyer, 73, order.id)

    {:ok, show, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/#{order.id}")

    show |> element("#order-send") |> render_click()
    show |> element("#order-confirm button", "Mark sent") |> render_click()
    assert render(show) =~ "marked as sent"
    assert has_element?(show, "#order-close")

    {:ok, list, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders?status=sent")

    assert has_element?(list, "#order-link-#{order.id}", "PO 1")
  end

  test "a viewer sees an order without actions and cannot forge a transition",
       %{conn: conn, scope: scope, buyer: buyer, supplier: supplier} do
    {:ok, order} =
      Purchasing.create_order(buyer, 73, %{supplier_id: supplier.id, currency_code: "XTS"})

    TestFixtures.revoke!(scope, 73, 91, @manage)

    {:ok, show, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/#{order.id}")

    assert has_element?(show, "#order-actions-forbidden")
    refute has_element?(show, "#order-submit")

    assert render_hook(show, "transition", %{"action" => "submit"}) =~
             "permission to change purchase orders"

    assert {:ok, %{status: "draft"}} = Purchasing.get_order(buyer, 73, order.id)

    {:ok, missing, _html} = conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/999")
    assert has_element?(missing, "#order-missing")
  end

  test "each transition needs its own capability, read again for every event",
       %{conn: conn, scope: scope, buyer: buyer, supplier: supplier, tax: tax} do
    {:ok, order} =
      Purchasing.create_order(buyer, 73, %{
        supplier_id: supplier.id,
        currency_code: "XTS",
        lines: [TestFixtures.line(%{tax_code_id: tax.id})]
      })

    {:ok, _} = Purchasing.submit_order(buyer, 73, order.id)

    {:ok, show, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/#{order.id}")

    # Holding the manage grant is no authority to approve or return.
    for action <- ~w(approve return) do
      assert render_hook(show, "transition", %{"action" => action}) =~
               "permission to change purchase orders"

      refute has_element?(show, "#order-confirm")
    end

    # A grant revoked after the page opened stops the next event.
    grant_capabilities!([@approve])

    {:ok, show, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/#{order.id}")

    assert has_element?(show, "#order-decide")

    TestFixtures.revoke!(scope, 73, 91, @approve)

    assert render_hook(show, "transition", %{"action" => "approve"}) =~
             "permission to change purchase orders"

    refute has_element?(show, "#order-confirm")
  end

  test "an amended order shows the request number and offers no return to draft",
       %{conn: conn, scope: scope, buyer: buyer, supplier: supplier} do
    approver = TestFixtures.sign_in!(scope, 73, 92, [@view, @manage, @approve])

    {:ok, order} =
      Purchasing.create_order(buyer, 73, %{
        supplier_id: supplier.id,
        currency_code: "XTS",
        lines: [TestFixtures.line()]
      })

    {:ok, _} = Purchasing.submit_order(buyer, 73, order.id)
    {:ok, _} = Purchasing.approve_order(approver, 73, order.id, %{})

    {:ok, _} =
      Purchasing.amend_order(buyer, 73, order.id, %{
        reason: "Higher price",
        lines: [TestFixtures.line(%{unit_price: "3"})]
      })

    grant_capabilities!([@approve])

    {:ok, show, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-orders/#{order.id}")

    assert has_element?(show, "#order-decide button", "Approve")
    refute has_element?(show, "#order-decide button", "Return to draft")
    assert has_element?(show, "#order-amendment-list", "Higher price")
  end
end
