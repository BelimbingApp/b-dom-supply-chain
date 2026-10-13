defmodule BilimbiWeb.SupplyChainReceiptsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures, as: PurchasingFixtures
  alias Bilimbi.SupplyChain.Receiving
  alias Bilimbi.SupplyChain.Receiving.TestFixtures

  @view "supply-chain.receiving.view"
  @configure "supply-chain.receiving.configuration.manage"
  @manage "supply-chain.receiving.receipts.manage"
  @post "supply-chain.receiving.receipts.post-receipt"

  @purchasing_view "supply-chain.purchasing.view"
  @purchasing_configure "supply-chain.purchasing.configuration.manage"
  @purchasing_manage "supply-chain.purchasing.orders.manage"
  @purchasing_approve "supply-chain.purchasing.orders.approve"
  @purchasing_receive "supply-chain.purchasing.orders.receive"

  # The signed-in user 91 keeps the store: every receiving capability plus
  # what receiving needs from purchasing. Users 92 and 93 buy and approve.
  @keeper [@view, @configure, @manage, @post, @purchasing_view, @purchasing_receive]

  setup do
    signed_in_identity!()
    PurchasingFixtures.create_purchasing_tables!()
    TestFixtures.create_receiving_tables!()
    UserFixtures.insert_user!(%{id: 92, company_id: 73, email: "buyer@example.test"})
    UserFixtures.insert_user!(%{id: 93, company_id: 73, email: "approver@example.test"})
    {:ok, scope} = Tenancy.scope(41)

    buyer =
      TestFixtures.sign_in!(scope, 73, 92, [
        @purchasing_view,
        @purchasing_configure,
        @purchasing_manage
      ])

    approver = TestFixtures.sign_in!(scope, 73, 93, [@purchasing_view, @purchasing_approve])

    order =
      TestFixtures.sent_order!(buyer, approver, 73, [
        PurchasingFixtures.line(%{description: "Bolts", quantity: "10", unit: "box"}),
        PurchasingFixtures.line(%{description: "Nuts", quantity: "5", unit: "bag"})
      ])

    %{scope: scope, buyer: buyer, order: order}
  end

  test "the pages need the view capability", %{conn: conn} do
    for path <- ["/supply-chain/receipts", "/supply-chain/receive", "/supply-chain/receipts/1"] do
      assert {:error, {:redirect, %{to: "/dashboard"}}} = conn |> log_in_as() |> live(path)
    end
  end

  test "a storekeeper receives against an order, posts the receipt, and reverses it",
       %{conn: conn, scope: scope, order: order} do
    grant_capabilities!(@keeper)
    keeper = TestFixtures.sign_in!(scope, 73, 91, [])
    [bolts, nuts] = order.lines

    {:ok, list, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts")
    assert has_element?(list, "#receipts-table-empty", "No goods receipts here")
    assert has_element?(list, "#receive-goods")

    {:ok, receive, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receive")
    refute has_element?(receive, "#receipt-form")

    receive
    |> form("#order-picker", picker: %{order_id: order.id})
    |> render_change()

    assert_patch(receive, ~p"/supply-chain/receive?order=#{order.id}")
    assert has_element?(receive, "#receipt-form-line-#{bolts.id}", "Bolts")

    receive
    |> form("#receipt-form",
      receipt: %{
        received_on: "2026-10-13",
        supplier_reference: "DN-7",
        lines: %{
          bolts.id => %{received_quantity: "4"},
          nuts.id => %{received_quantity: "3", rejected_quantity: "1", rejection_reason: "Torn"}
        }
      }
    )
    |> render_submit()

    {:ok, [receipt]} = Receiving.list_receipts(keeper, 73)
    assert_redirect(receive, ~p"/supply-chain/receipts/#{receipt.id}")

    assert %{status: "draft", supplier_reference: "DN-7", lines: [_, %{rejection_reason: "Torn"}]} =
             receipt

    {:ok, show, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts/#{receipt.id}")
    assert has_element?(show, "#receipt-lines-table td", "Bolts")
    assert has_element?(show, "#receipt-events li", "Draft")
    assert has_element?(show, "#receipt-order-link", "PO #{order.order_number}")

    show |> element("#receipt-post") |> render_click()
    show |> element("#receipt-confirm button", "Post") |> render_click()
    assert render(show) =~ "Receipt posted"
    assert has_element?(show, "#receipt-events li", "Posted")
    refute has_element?(show, "#receipt-post")
    assert has_element?(show, "#receipt-reverse")

    assert {:ok, %{status: "partially_received", lines: [%{received_quantity: four}, _]}} =
             Purchasing.get_order(keeper, 73, order.id)

    assert Decimal.equal?(four, "4")

    show
    |> form("#receipt-reverse", %{reason: "Wrong pallet"})
    |> render_submit()

    show |> element("#receipt-confirm button", "Reverse") |> render_click()

    {:ok, [reversal, _original]} = Receiving.list_receipts(keeper, 73)
    assert_redirect(show, ~p"/supply-chain/receipts/#{reversal.id}")
    assert %{kind: "reversal", status: "posted", reason: "Wrong pallet"} = reversal

    assert {:ok, %{lines: [%{received_quantity: zero}, _]}} =
             Purchasing.get_order(keeper, 73, order.id)

    assert Decimal.equal?(zero, 0)

    {:ok, reversed, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/receipts/#{reversal.id}")

    assert has_element?(reversed, "#receipt-reverses-link", "GR #{receipt.receipt_number}")
    assert has_element?(reversed, "#receipt-final")

    {:ok, original, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/receipts/#{receipt.id}")

    assert has_element?(original, "#receipt-reversed-by-link", "GR #{reversal.receipt_number}")
    refute has_element?(original, "#receipt-reverse")

    {:ok, list, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts?status=posted")
    assert has_element?(list, "#receipt-link-#{receipt.id}", "GR #{receipt.receipt_number}")
    assert has_element?(list, "#receipt-link-#{reversal.id}", "GR #{reversal.receipt_number}")
  end

  test "a refused draft stays on the form with its reason, and a draft is cancelled",
       %{conn: conn, scope: scope, order: order} do
    grant_capabilities!(@keeper)
    [bolts, _nuts] = order.lines

    {:ok, receive, _html} =
      conn |> log_in_as() |> live(~p"/supply-chain/receive?order=#{order.id}")

    html =
      receive
      |> form("#receipt-form", receipt: %{lines: %{bolts.id => %{received_quantity: "11"}}})
      |> render_submit()

    assert html =~ "exceeds what the order line has left to receive"
    assert has_element?(receive, "#receipt-form-line-#{bolts.id} input[value='11']")

    html =
      receive
      |> form("#receipt-form", receipt: %{lines: %{bolts.id => %{received_quantity: ""}}})
      |> render_submit()

    assert html =~ "at least one line"

    receive
    |> form("#receipt-form", receipt: %{lines: %{bolts.id => %{received_quantity: "1"}}})
    |> render_submit()

    keeper = TestFixtures.sign_in!(scope, 73, 91, [])
    {:ok, [receipt]} = Receiving.list_receipts(keeper, 73)

    {:ok, show, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts/#{receipt.id}")
    show |> form("#receipt-cancel", %{reason: "Never arrived"}) |> render_submit()
    show |> element("#receipt-confirm button", "Cancel receipt") |> render_click()
    assert render(show) =~ "Draft receipt cancelled"
    assert has_element?(show, "#receipt-final")
    assert {:ok, %{status: "cancelled"}} = Receiving.get_receipt(keeper, 73, receipt.id)

    {:ok, unavailable, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receive?order=999")
    assert has_element?(unavailable, "#order-unavailable")

    {:ok, missing, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts/999")
    assert has_element?(missing, "#receipt-missing")
  end

  test "each action needs its own capability, read again for every event",
       %{conn: conn, scope: scope, order: order} do
    grant_capabilities!([@view, @manage, @purchasing_view, @purchasing_receive])
    keeper = TestFixtures.sign_in!(scope, 73, 91, [])
    [bolts, _nuts] = order.lines

    {:ok, receipt} =
      Receiving.create_receipt(keeper, 73, %{
        order_id: order.id,
        lines: [TestFixtures.line(bolts, %{received_quantity: "1"})]
      })

    {:ok, show, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts/#{receipt.id}")
    assert has_element?(show, "#receipt-cancel")
    refute has_element?(show, "#receipt-post")

    # Holding the manage grant is no authority to post.
    assert render_hook(show, "transition", %{"action" => "post"}) =~
             "permission to change goods receipts"

    refute has_element?(show, "#receipt-confirm")
    assert {:ok, %{status: "draft"}} = Receiving.get_receipt(keeper, 73, receipt.id)

    # A grant revoked after the page opened stops the next event.
    grant_capabilities!([@post])
    {:ok, show, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts/#{receipt.id}")
    assert has_element?(show, "#receipt-post")
    TestFixtures.revoke!(scope, 73, 91, @post)

    assert render_hook(show, "transition", %{"action" => "post"}) =~
             "permission to change goods receipts"

    refute has_element?(show, "#receipt-confirm")

    # A viewer sees the receive page without its form and cannot forge a save.
    TestFixtures.revoke!(scope, 73, 91, @manage)
    {:ok, receive, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receive")
    assert has_element?(receive, "#receive-forbidden")
    refute has_element?(receive, "#order-picker")

    assert render_hook(receive, "save", %{"receipt" => %{"lines" => %{}}}) =~
             "permission to record goods receipts"

    {:ok, show, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts/#{receipt.id}")
    assert has_element?(show, "#receipt-actions-forbidden")
    refute has_element?(show, "#receipt-cancel")
    assert {:ok, [_]} = Receiving.list_receipts(keeper, 73)
  end

  test "a configurer sets the over-receipt tolerance; a storekeeper without the grant cannot",
       %{conn: conn, scope: scope} do
    grant_capabilities!([@view, @configure])
    {:ok, list, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts")
    assert has_element?(list, "#settings-current", "up to 0 % over")

    list
    |> form("#settings-form", settings: %{over_receipt_tolerance_percent: "2.5"})
    |> render_submit()

    assert render(list) =~ "tolerance set to 2.5 %"
    assert has_element?(list, "#settings-current", "Set by user 91")

    html =
      list
      |> form("#settings-form", settings: %{over_receipt_tolerance_percent: "101"})
      |> render_submit()

    assert html =~ "less than or equal to 100"

    TestFixtures.revoke!(scope, 73, 91, @configure)

    assert render_hook(list, "save_settings", %{
             "settings" => %{"over_receipt_tolerance_percent" => "9"}
           }) =~ "permission to configure receiving"

    keeper = TestFixtures.sign_in!(scope, 73, 91, [])

    assert {:ok, %{over_receipt_tolerance_percent: tolerance}} =
             Receiving.get_settings(keeper, 73)

    assert Decimal.equal?(tolerance, "2.5")

    {:ok, list, _html} = conn |> log_in_as() |> live(~p"/supply-chain/receipts")
    refute has_element?(list, "#settings-form")
  end
end
