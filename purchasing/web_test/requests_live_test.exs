defmodule BilimbiWeb.SupplyChainRequestsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures

  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"
  @manage "supply-chain.purchasing.requests.manage"
  @approve "supply-chain.purchasing.requests.approve"
  @manage_orders "supply-chain.purchasing.orders.manage"

  setup do
    signed_in_identity!()
    TestFixtures.create_purchasing_tables!()
    UserFixtures.insert_user!(%{id: 92, company_id: 73, email: "approver@example.test"})
    {:ok, scope} = Tenancy.scope(41)
    %{scope: scope}
  end

  test "the page needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/supply-chain/purchase-requests")
  end

  test "a requester drafts and submits, an approver approves, and the request becomes an order",
       %{conn: conn, scope: scope} do
    grant_capabilities!([@view, @configure, @manage, @manage_orders])
    grant_capabilities!([@view, @approve], user_id: 92)

    requester = TestFixtures.sign_in!(scope, 73, 91, [])

    {:ok, supplier} =
      Purchasing.create_supplier(requester, 73, TestFixtures.supplier_attributes(%{code: "s"}))

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/supply-chain/purchase-requests")
    assert has_element?(view, "#requests-table-empty", "No purchase requests here")

    view
    |> form("#request-form",
      request: %{
        title: "Chairs",
        needed_on: "2026-11-15",
        lines: %{
          "0" => %{description: "Chair", quantity: "2", unit: "unit"},
          "1" => %{description: ""}
        }
      }
    )
    |> render_submit()

    assert render(view) =~ "saved as a draft"
    assert has_element?(view, "#requests-table td", "Chairs")

    {:ok, [request]} = Purchasing.list_requests(requester, 73)
    assert length(request.lines) == 1

    view |> element("#request-actions-#{request.id} button", "Submit") |> render_click()
    view |> element("#request-confirm button", "Submit") |> render_click()
    assert render(view) =~ "submitted for approval"
    assert {:ok, %{status: "submitted"}} = Purchasing.get_request(requester, 73, request.id)

    # The requester holds no approval grant, so the decision form is absent.
    refute has_element?(view, "#decide-#{request.id}")

    {:ok, approval, _html} =
      conn
      |> log_in_as(session_user(%{"user_id" => 92}))
      |> live(~p"/supply-chain/purchase-requests?status=submitted")

    approval
    |> form("#decide-#{request.id}", %{reason: "Within budget"})
    |> render_submit(%{"decision" => "approve"})

    approval |> element("#request-confirm button", "Approve") |> render_click()
    assert render(approval) =~ "Request approved."

    assert {:ok, %{status: "approved", decided_by_user_id: 92}} =
             Purchasing.get_request(requester, 73, request.id)

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/purchase-requests?status=approved")

    view
    |> form("#order-from-#{request.id}", %{supplier_id: supplier.id, currency_code: "XTS"})
    |> render_submit()

    assert_redirect(view, ~p"/supply-chain/purchase-orders/1")

    assert {:ok, [%{purchase_request_id: request_id, lines: [%{description: "Chair"}]}]} =
             Purchasing.list_orders(requester, 73)

    assert request_id == request.id
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!([@view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/supply-chain/purchase-requests")
    refute has_element?(view, "#request-form")

    assert render_hook(view, "save", %{"request" => %{"title" => "x"}}) =~
             "permission to work on purchase requests"
  end
end
