defmodule Bilimbi.SupplyChain.Purchasing.OrdersTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"
  @manage "supply-chain.purchasing.orders.manage"
  @approve "supply-chain.purchasing.orders.approve"
  @receive "supply-chain.purchasing.orders.receive"

  setup do
    context = TestFixtures.setup_purchasing!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    buyer =
      TestFixtures.sign_in!(context.first_scope, 73, 91, [@view, @configure, @manage, @receive])

    approver = TestFixtures.sign_in!(context.first_scope, 73, 92, [@view, @manage, @approve])

    {:ok, supplier} =
      Purchasing.create_supplier(buyer, 73, TestFixtures.supplier_attributes(%{code: "main"}))

    {:ok, tax} =
      Purchasing.create_tax_code(buyer, 73, %{code: "std", name: "Standard", rate: "10"})

    Map.merge(context, %{buyer: buyer, approver: approver, supplier: supplier, tax: tax})
  end

  defp draft(context, overrides \\ %{}) do
    {:ok, order} =
      Purchasing.create_order(
        context.buyer,
        73,
        Map.merge(
          %{
            supplier_id: context.supplier.id,
            currency_code: "xts",
            reference: "Q-1",
            lines: original_lines(context)
          },
          overrides
        )
      )

    order
  end

  defp original_lines(context) do
    [
      TestFixtures.line(%{quantity: "10", unit_price: "2.50", tax_code_id: context.tax.id}),
      TestFixtures.line(%{description: "Second", quantity: "1", unit_price: "100"})
    ]
  end

  defp approved(context) do
    order = draft(context)
    {:ok, _} = Purchasing.submit_order(context.buyer, 73, order.id)

    {:ok, order} =
      Purchasing.approve_order(context.approver, 73, order.id, %{reason: "Within budget"})

    order
  end

  defp sent(context) do
    order = approved(context)
    {:ok, order} = Purchasing.send_order(context.buyer, 73, order.id)
    order
  end

  describe "drafting" do
    test "stores the header, lines with snapshotted tax, totals, and a creation event", context do
      order = draft(context)

      assert %{
               order_number: 1,
               status: "draft",
               currency_code: "XTS",
               reference: "Q-1",
               amendment_count: 0,
               created_by_user_id: 91,
               supplier: %{code: "main"},
               events: [%{from_status: nil, to_status: "draft", actor_user_id: 91, reason: nil}],
               amendments: []
             } = order

      assert [
               %{line_number: 1, tax_code_id: tax_id, tax_rate: rate, line_total: first_total},
               %{line_number: 2, tax_code_id: nil, tax_rate: nil}
             ] = order.lines

      assert tax_id == context.tax.id
      assert Decimal.equal?(rate, "10")
      assert Decimal.equal?(first_total, "25")
      assert Decimal.equal?(order.subtotal, "125")
      assert Decimal.equal?(order.tax_total, "2.5")
      assert Decimal.equal?(order.total, "127.5")
      assert {:ok, ^order} = Purchasing.get_order(context.buyer, 73, order.id)
      assert {:ok, ^order} = Purchasing.find_order_by_number(context.buyer, 73, 1)
      assert {:ok, [%{id: id}]} = Purchasing.list_orders(context.buyer, 73)
      assert id == order.id
    end

    test "accepts string keys, as a form sends them", context do
      assert {:ok, %{lines: [%{description: "Typed"}]}} =
               Purchasing.create_order(context.buyer, 73, %{
                 "supplier_id" => context.supplier.id,
                 "currency_code" => "XTS",
                 "lines" => [
                   %{
                     "description" => "Typed",
                     "quantity" => "1",
                     "unit" => "ea",
                     "unit_price" => "1"
                   }
                 ]
               })
    end

    test "refuses a bad line, a foreign tax code, and an inactive or missing supplier", context do
      %{buyer: buyer, supplier: supplier} = context

      assert {:error, changeset} =
               Purchasing.create_order(buyer, 73, %{
                 supplier_id: supplier.id,
                 currency_code: "XTS",
                 lines: [
                   TestFixtures.line(%{quantity: "0", unit_price: "-1", tax_code_id: 0}),
                   TestFixtures.line(%{description: ""})
                 ]
               })

      assert %{lines: [first, second]} = errors_on(changeset)
      assert %{quantity: [_], unit_price: [_], tax_code_id: [_]} = first
      assert %{description: [_]} = second

      assert {:error, changeset} =
               Purchasing.create_order(buyer, 73, %{supplier_id: supplier.id, currency_code: "x"})

      assert %{currency_code: [_]} = errors_on(changeset)

      assert {:error, :supplier_not_found} =
               Purchasing.create_order(buyer, 73, %{supplier_id: 0, currency_code: "XTS"})

      {:ok, _} = Purchasing.update_supplier(buyer, 73, supplier.id, %{active: false})

      assert {:error, :supplier_inactive} =
               Purchasing.create_order(buyer, 73, %{
                 supplier_id: supplier.id,
                 currency_code: "XTS"
               })
    end

    test "changes a draft's header and replaces its lines", context do
      order = draft(context)

      assert {:ok, updated} =
               Purchasing.update_order(context.buyer, 73, order.id, %{
                 reference: "Q-2",
                 lines: [TestFixtures.line(%{description: "Only"})]
               })

      assert %{reference: "Q-2", lines: [%{line_number: 1, description: "Only"}]} = updated

      assert {:error, changeset} =
               Purchasing.update_order(context.buyer, 73, order.id, %{
                 lines: [TestFixtures.line(%{quantity: "x"})]
               })

      assert %{lines: [%{quantity: [_]}]} = errors_on(changeset)

      assert {:ok, %{lines: [%{description: "Only"}]}} =
               Purchasing.get_order(context.buyer, 73, order.id)
    end

    test "numbers each company's orders in creation order without gaps", context do
      %{first_scope: system, buyer: buyer, supplier: supplier} = context

      assert %{order_number: 1} = draft(context)

      assert {:error, %Ecto.Changeset{}} =
               Purchasing.create_order(buyer, 73, %{supplier_id: supplier.id, currency_code: "x"})

      assert %{order_number: 2} = second = draft(context)

      assert {:ok, %{status: "cancelled"}} =
               Purchasing.cancel_order(buyer, 73, second.id, %{reason: "Dup"})

      assert %{order_number: 3} = draft(context)

      sibling = TestFixtures.sign_in!(system, 74, 93, [@view, @configure, @manage])

      {:ok, other_supplier} =
        Purchasing.create_supplier(sibling, 74, TestFixtures.supplier_attributes(%{code: "s"}))

      assert {:ok, %{order_number: 1}} =
               Purchasing.create_order(sibling, 74, %{
                 supplier_id: other_supplier.id,
                 currency_code: "XTS"
               })

      # A writer's own number is replaced by the database's.
      %{rows: [[number]]} =
        SQL.query!(
          Repo,
          """
          INSERT INTO supply_chain_purchasing_orders
            (tenant_id, company_id, order_number, supplier_id, currency_code, created_by_user_id,
             inserted_at, updated_at)
          VALUES (41, 73, 1, #{supplier.id}, 'XTS', 91, now(), now())
          RETURNING order_number
          """,
          []
        )

      assert number == 4
    end
  end

  describe "approval" do
    test "runs draft, submitted, approved, sent, received, closed with an audited event each",
         context do
      %{first_scope: system, buyer: buyer, approver: approver} = context
      order = draft(context)

      assert {:error, :no_lines} =
               draft(context, %{lines: []}) |> then(&Purchasing.submit_order(buyer, 73, &1.id))

      assert {:ok, %{status: "submitted", submitted_by_user_id: 91, submitted_at: %DateTime{}}} =
               Purchasing.submit_order(buyer, 73, order.id)

      assert {:error, :unauthorized} = Purchasing.approve_order(buyer, 73, order.id, %{})
      # The submitter holding the approver's grant still cannot approve their own order.
      approver_too = TestFixtures.sign_in!(system, 73, 91, [@approve])
      assert {:error, :own_order} = Purchasing.approve_order(approver_too, 73, order.id, %{})

      assert {:ok, approved} =
               Purchasing.approve_order(approver, 73, order.id, %{reason: "Budget ok"})

      assert %{status: "approved", approved_by_user_id: 92, approved_at: %DateTime{}} = approved

      assert {:ok, %{status: "sent", sent_at: %DateTime{}}} =
               Purchasing.send_order(buyer, 73, order.id)

      [first, second] = approved.lines

      assert {:ok, partial} =
               Purchasing.record_receipt(buyer, 73, order.id, %{
                 lines: [%{line_id: first.id, quantity: "4"}]
               })

      assert %{status: "partially_received"} = partial
      assert [%{received_quantity: received}, _] = partial.lines
      assert Decimal.equal?(received, "4")

      assert {:ok, closed} =
               Purchasing.record_receipt(buyer, 73, order.id, %{
                 lines: [
                   %{line_id: first.id, quantity: "6"},
                   %{line_id: second.id, quantity: "1"}
                 ]
               })

      assert %{status: "closed", closed_at: %DateTime{}} = closed

      assert Enum.map(closed.events, &{&1.from_status, &1.to_status, &1.actor_user_id, &1.reason}) ==
               [
                 {nil, "draft", 91, nil},
                 {"draft", "submitted", 91, nil},
                 {"submitted", "approved", 92, "Budget ok"},
                 {"approved", "sent", 91, nil},
                 {"sent", "partially_received", 91, nil},
                 {"partially_received", "closed", 91, "every line received in full"}
               ]

      assert Enum.all?(closed.events, &match?(%DateTime{}, &1.occurred_at))

      assert {:error, {:invalid_transition, "closed", "cancelled"}} =
               Purchasing.cancel_order(buyer, 73, order.id, %{reason: "Too late"})
    end

    test "needs the approver's grant and refuses a transition that does not apply", context do
      %{first_scope: system, buyer: buyer, approver: approver} = context
      order = draft(context)

      assert {:error, {:invalid_transition, "draft", "approved"}} =
               Purchasing.approve_order(approver, 73, order.id, %{})

      assert {:error, {:invalid_transition, "draft", "sent"}} =
               Purchasing.send_order(buyer, 73, order.id)

      {:ok, _} = Purchasing.submit_order(buyer, 73, order.id)

      assert {:error, {:invalid_transition, "submitted", "draft"}} =
               Purchasing.update_order(buyer, 73, order.id, %{reference: "late"})

      TestFixtures.revoke!(system, 73, 92, @approve)
      assert {:error, :unauthorized} = Purchasing.approve_order(approver, 73, order.id, %{})
      assert {:error, :order_not_found} = Purchasing.submit_order(buyer, 73, order.id + 100)
      assert {:error, :unauthorized} = Purchasing.submit_order(system, 73, order.id)
    end

    test "returns a submitted order to draft with a reason, and cancels with one", context do
      %{buyer: buyer, approver: approver} = context
      order = draft(context)
      {:ok, _} = Purchasing.submit_order(buyer, 73, order.id)

      assert {:error, changeset} = Purchasing.return_order(approver, 73, order.id, %{reason: " "})
      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, %{status: "draft", submitted_by_user_id: nil, submitted_at: nil}} =
               Purchasing.return_order(approver, 73, order.id, %{reason: "Wrong supplier"})

      assert {:ok, %{reference: "Fixed"}} =
               Purchasing.update_order(buyer, 73, order.id, %{reference: "Fixed"})

      {:ok, _} = Purchasing.submit_order(buyer, 73, order.id)
      {:ok, _} = Purchasing.approve_order(approver, 73, order.id, %{})

      # Cancelling after approval needs the approver's capability too.
      assert {:error, :unauthorized} =
               Purchasing.cancel_order(buyer, 73, order.id, %{reason: "No"})

      assert {:ok, %{status: "cancelled", cancelled_at: %DateTime{}, events: events}} =
               Purchasing.cancel_order(approver, 73, order.id, %{reason: "Supplier closed"})

      assert %{from_status: "approved", to_status: "cancelled", reason: "Supplier closed"} =
               List.last(events)
    end

    test "records the operator behind an impersonated session", context do
      %{first_scope: system} = context
      TestFixtures.sign_in!(system, 73, 95, [@manage])

      impersonated =
        Authentication.sign_in(system, 95, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      assert {:ok, order} =
               Purchasing.create_order(impersonated, 73, %{
                 supplier_id: context.supplier.id,
                 currency_code: "XTS"
               })

      assert %{created_by_user_id: 95, created_by_impersonator_id: 91} = order
      assert [%{actor_user_id: 95, actor_impersonator_id: 91}] = order.events
    end
  end

  describe "immutability" do
    test "an approved order changes only through an amendment that keeps the old lines",
         context do
      %{buyer: buyer} = context
      order = approved(context)
      [first, second] = order.lines

      assert {:error, {:invalid_transition, "approved", "draft"}} =
               Purchasing.update_order(buyer, 73, order.id, %{reference: "late"})

      assert_raise Postgrex.Error, ~r/changes only by a transition or an amendment/, fn ->
        SQL.query!(
          Repo,
          "UPDATE supply_chain_purchasing_orders SET reference = 'x' WHERE id = $1",
          [order.id]
        )
      end

      assert_raise Postgrex.Error, ~r/lines change only by an amendment or a receipt/, fn ->
        SQL.query!(
          Repo,
          "UPDATE supply_chain_purchasing_order_lines SET quantity = 1 WHERE id = $1",
          [first.id]
        )
      end

      assert_raise Postgrex.Error, ~r/its lines are kept/, fn ->
        SQL.query!(Repo, "DELETE FROM supply_chain_purchasing_order_lines WHERE id = $1", [
          first.id
        ])
      end

      assert {:error, changeset} =
               Purchasing.amend_order(buyer, 73, order.id, %{lines: [TestFixtures.line()]})

      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      assert {:error, :no_lines} =
               Purchasing.amend_order(buyer, 73, order.id, %{reason: "r", lines: []})

      assert {:ok, amended} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "Delivery date agreed",
                 expected_on: "2026-11-01",
                 lines: original_lines(context)
               })

      assert %{
               status: "approved",
               amendment_count: 1,
               expected_on: ~D[2026-11-01],
               reference: "Q-1"
             } =
               amended

      assert [%{line_number: 1, description: "An item", amendment_id: amendment_id}, _] =
               amended.lines

      assert Decimal.equal?(amended.total, order.total)

      assert [
               %{
                 id: ^amendment_id,
                 amendment_number: 1,
                 reason: "Delivery date agreed",
                 amended_by_user_id: 91,
                 occurred_at: %DateTime{},
                 lines: [%{description: "An item"}, %{description: "Second"}],
                 superseded_line_ids: superseded
               }
             ] = amended.amendments

      assert Enum.sort(superseded) == Enum.sort([first.id, second.id])

      # The replaced lines stay readable, marked with the amendment.
      assert {:ok,
              %{
                superseded_by_amendment_id: ^amendment_id,
                order_number: 1,
                order_status: "approved"
              }} =
               Purchasing.get_order_line(buyer, 73, first.id)

      assert {:ok, %{status: "approved", amendment_count: 2}} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "Again",
                 notes: "Call before delivery",
                 lines: original_lines(context)
               })
    end

    test "an amendment that changes no line is manage-only, recorded, and keeps the status",
         context do
      %{buyer: buyer} = context
      order = sent(context)

      assert {:ok, %{status: "sent", amendment_count: 1, sent_at: %DateTime{}} = amended} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "Same lines, scale differs",
                 lines: [
                   TestFixtures.line(%{
                     quantity: "10.0",
                     unit_price: "2.5",
                     tax_code_id: context.tax.id
                   }),
                   TestFixtures.line(%{
                     description: "Second",
                     quantity: "1.00",
                     unit_price: "100.0"
                   })
                 ]
               })

      assert Enum.map(amended.events, & &1.to_status) == ~w(draft submitted approved sent)
    end

    test "a sent order is amended, a partially received one is not", context do
      %{buyer: buyer} = context
      order = sent(context)

      assert {:ok, %{status: "sent", amendment_count: 1}} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "r",
                 lines: original_lines(context)
               })

      {:ok, %{lines: [line | _]}} = Purchasing.get_order(buyer, 73, order.id)

      {:ok, _} =
        Purchasing.record_receipt(buyer, 73, order.id, %{
          lines: [%{line_id: line.id, quantity: "1"}]
        })

      assert {:error, {:invalid_transition, "partially_received", "amended"}} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "r",
                 lines: original_lines(context)
               })

      assert {:ok, %{status: "closed", events: events}} =
               Purchasing.close_order(buyer, 73, order.id, %{reason: "Rest cancelled by supplier"})

      assert %{to_status: "closed", reason: "Rest cancelled by supplier"} = List.last(events)
    end

    test "the database refuses an amendment, a transition, or a creation without its record",
         context do
      order = approved(context)

      assert_raise Postgrex.Error, ~r/only an approved or sent order is amended/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO supply_chain_purchasing_order_amendments (tenant_id, company_id, order_id, reason, amended_by_user_id, occurred_at) VALUES (41, 73, $1, 'r', 91, now())",
          [draft(context).id]
        )
      end

      SQL.query!(
        Repo,
        "UPDATE supply_chain_purchasing_orders SET amendment_count = 1 WHERE id = $1",
        [
          order.id
        ]
      )

      assert_raise Postgrex.Error, ~r/counts amendment 1 without its record/, fn ->
        TestFixtures.check_deferred_constraints!()
      end
    end

    test "history rows and amendments are append-only", context do
      order = sent(context)

      for sql <- [
            "UPDATE supply_chain_purchasing_order_events SET reason = 'x'",
            "DELETE FROM supply_chain_purchasing_order_events",
            "TRUNCATE supply_chain_purchasing_order_lines",
            "DELETE FROM supply_chain_purchasing_orders WHERE id = #{order.id}"
          ] do
        assert_raise Postgrex.Error, ~r/supply chain purchasing keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end
    end
  end

  describe "amendments that change what was approved" do
    test "a buyer without the approver's grant cannot change the lines and send the order",
         context do
      %{buyer: buyer, approver: approver} = context
      order = approved(context)

      cheaper =
        context
        |> original_lines()
        |> List.update_at(1, &Map.put(&1, :unit_price, "1"))

      assert {:ok, amended} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "Cheaper second line",
                 lines: cheaper
               })

      assert %{
               status: "submitted",
               amendment_count: 1,
               submitted_by_user_id: 91,
               approved_by_user_id: nil,
               approved_at: nil,
               sent_at: nil
             } = amended

      assert Decimal.equal?(amended.total, "28.5")

      assert %{from_status: "approved", to_status: "submitted", actor_user_id: 91} =
               reason_event = List.last(amended.events)

      assert reason_event.reason == "Cheaper second line"

      assert {:error, {:invalid_transition, "submitted", "sent"}} =
               Purchasing.send_order(buyer, 73, order.id)

      assert {:error, :unauthorized} = Purchasing.approve_order(buyer, 73, order.id, %{})

      assert {:error, {:invalid_transition, "submitted", "draft"}} =
               Purchasing.return_order(approver, 73, order.id, %{reason: "Redo"})

      assert {:error, :unauthorized} =
               Purchasing.cancel_order(buyer, 73, order.id, %{reason: "Undo the approval"})

      assert {:ok, %{status: "approved", approved_by_user_id: 92}} =
               Purchasing.approve_order(approver, 73, order.id, %{reason: "Reviewed the change"})

      assert {:ok, %{status: "sent"}} = Purchasing.send_order(buyer, 73, order.id)
    end

    test "the amender of an approved order cannot approve their own change", context do
      %{first_scope: system, approver: approver} = context
      second_approver = TestFixtures.sign_in!(system, 73, 93, [@view, @manage, @approve])
      order = approved(context)

      assert {:ok, %{status: "submitted", submitted_by_user_id: 92}} =
               Purchasing.amend_order(approver, 73, order.id, %{
                 reason: "More units",
                 lines: List.update_at(original_lines(context), 0, &Map.put(&1, :quantity, "20"))
               })

      assert {:error, :own_order} = Purchasing.approve_order(approver, 73, order.id, %{})

      assert {:ok, %{status: "approved", approved_by_user_id: 93}} =
               Purchasing.approve_order(second_approver, 73, order.id, %{})
    end

    test "a sent order goes back for approval and is sent again", context do
      %{buyer: buyer, approver: approver} = context
      order = sent(context)

      assert {:ok, %{status: "submitted", sent_at: nil}} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "Other tax code",
                 lines:
                   List.update_at(
                     original_lines(context),
                     1,
                     &Map.put(&1, :tax_code_id, context.tax.id)
                   )
               })

      assert {:error, {:invalid_transition, "submitted", "received"}} =
               Purchasing.record_receipt(buyer, 73, order.id, %{
                 lines: [%{line_id: hd(order.lines).id, quantity: "1"}]
               })

      assert {:ok, _} = Purchasing.approve_order(approver, 73, order.id, %{})

      assert {:ok, %{status: "sent", sent_at: %DateTime{}} = resent} =
               Purchasing.send_order(buyer, 73, order.id)

      assert Enum.map(resent.events, &{&1.from_status, &1.to_status}) == [
               {nil, "draft"},
               {"draft", "submitted"},
               {"submitted", "approved"},
               {"approved", "sent"},
               {"sent", "submitted"},
               {"submitted", "approved"},
               {"approved", "sent"}
             ]
    end

    test "every change to a line sends the order back for approval", context do
      %{buyer: buyer, approver: approver} = context

      changes = [
        &Map.put(&1, :description, "A different item"),
        &Map.put(&1, :external_item_ref, "SKU-9"),
        &Map.put(&1, :unit, "box"),
        &Map.put(&1, :quantity, "11"),
        &Map.put(&1, :unit_price, "2.51"),
        &Map.delete(&1, :tax_code_id)
      ]

      for change <- changes do
        order = approved(context)

        assert {:ok, %{status: "submitted"}} =
                 Purchasing.amend_order(buyer, 73, order.id, %{
                   reason: "Changed",
                   lines: List.update_at(original_lines(context), 0, change)
                 })
      end

      order = approved(context)

      assert {:ok, %{status: "submitted"}} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: "A line fewer",
                 lines: Enum.take(original_lines(context), 1)
               })

      assert {:ok, %{status: "cancelled"}} =
               Purchasing.cancel_order(approver, 73, order.id, %{reason: "Dropped"})
    end

    test "the database allows the way back to submitted only with the amendment's record",
         context do
      order = approved(context)

      SQL.query!(
        Repo,
        "UPDATE supply_chain_purchasing_orders SET status = 'submitted', submitted_by_user_id = 91, submitted_at = now(), approved_by_user_id = NULL, approved_at = NULL WHERE id = $1",
        [order.id]
      )

      SQL.query!(
        Repo,
        "INSERT INTO supply_chain_purchasing_order_events (tenant_id, company_id, order_id, from_status, to_status, actor_user_id, occurred_at) VALUES (41, 73, $1, 'approved', 'submitted', 91, now())",
        [order.id]
      )

      assert_raise Postgrex.Error, ~r/went back to submitted without an amendment/, fn ->
        TestFixtures.check_deferred_constraints!()
      end
    end
  end

  describe "reasons" do
    test "are limited by characters, not bytes", context do
      %{buyer: buyer} = context

      assert {:error, changeset} =
               Purchasing.cancel_order(buyer, 73, draft(context).id, %{
                 reason: String.duplicate("あ", 501)
               })

      assert %{reason: ["should be at most 500 character(s)"]} = errors_on(changeset)

      assert {:ok, %{status: "cancelled"}} =
               Purchasing.cancel_order(buyer, 73, draft(context).id, %{
                 reason: String.duplicate("あ", 300)
               })
    end
  end

  describe "text bounds" do
    test "count codepoints, as the varchar columns do, so a refusal is an error not a crash",
         context do
      %{buyer: buyer} = context
      combining = String.duplicate("e\u0301", 300)

      assert {:error, changeset} =
               Purchasing.cancel_order(buyer, 73, draft(context).id, %{reason: combining})

      assert %{reason: ["should be at most 500 character(s)"]} = errors_on(changeset)

      assert {:error, changeset} =
               Purchasing.create_order(buyer, 73, %{
                 supplier_id: context.supplier.id,
                 currency_code: "XTS",
                 reference: String.duplicate("e\u0301", 60),
                 notes: String.duplicate("e\u0301", 600),
                 lines: [TestFixtures.line(%{description: combining})]
               })

      assert %{
               reference: [_],
               notes: [_],
               lines: [%{description: ["should be at most 500 character(s)"]}]
             } = errors_on(changeset)

      order = approved(context)

      assert {:error, changeset} =
               Purchasing.amend_order(buyer, 73, order.id, %{
                 reason: combining,
                 lines: original_lines(context)
               })

      assert %{reason: [_]} = errors_on(changeset)
    end
  end

  describe "receipts" do
    test "add up per line, never exceed the order, and need the receiving grant", context do
      %{first_scope: system, buyer: buyer} = context
      order = sent(context)
      [first, _second] = order.lines

      assert {:error, changeset} =
               Purchasing.record_receipt(buyer, 73, order.id, %{
                 lines: [%{line_id: first.id, quantity: "11"}]
               })

      assert %{lines: [%{received_quantity: [_]}]} = errors_on(changeset)

      assert {:error, changeset} = Purchasing.record_receipt(buyer, 73, order.id, %{lines: []})
      assert %{lines: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Purchasing.record_receipt(buyer, 73, order.id, %{
                 lines: [%{line_id: 0, quantity: "1"}]
               })

      assert %{lines: [%{line_id: [_]}]} = errors_on(changeset)

      assert {:error, changeset} =
               Purchasing.record_receipt(buyer, 73, order.id, %{
                 lines: [%{line_id: first.id, quantity: "3"}, %{line_id: first.id, quantity: "3"}]
               })

      assert %{lines: ["can name each line only once"]} = errors_on(changeset)

      {:ok, unchanged} = Purchasing.get_order(buyer, 73, order.id)
      assert [%{received_quantity: zero}, _] = unchanged.lines
      assert Decimal.equal?(zero, "0")
      assert %{status: "sent"} = unchanged

      {:ok, _} =
        Purchasing.record_receipt(buyer, 73, order.id, %{
          lines: [%{line_id: first.id, quantity: "3"}]
        })

      {:ok, order} =
        Purchasing.record_receipt(buyer, 73, order.id, %{
          lines: [%{line_id: first.id, quantity: "3"}]
        })

      assert [%{received_quantity: six}, _] = order.lines
      assert Decimal.equal?(six, "6")

      clerk = TestFixtures.sign_in!(system, 73, 94, [@view, @manage])

      assert {:error, :unauthorized} =
               Purchasing.record_receipt(clerk, 73, order.id, %{
                 lines: [%{line_id: first.id, quantity: "1"}]
               })

      assert {:error, {:invalid_transition, "approved", "received"}} =
               Purchasing.record_receipt(buyer, 73, approved(context).id, %{
                 lines: [%{line_id: first.id, quantity: "1"}]
               })
    end
  end

  describe "reads" do
    test "filter by status and supplier, page by limit, and refuse a malformed option", context do
      %{buyer: buyer, approver: approver} = context
      first = draft(context)
      second = draft(context)
      {:ok, _} = Purchasing.submit_order(buyer, 73, second.id)
      {:ok, _} = Purchasing.approve_order(approver, 73, second.id, %{})

      assert {:ok, [%{id: second_id}, %{id: first_id}]} = Purchasing.list_orders(buyer, 73)
      assert {second_id, first_id} == {second.id, first.id}
      assert {:ok, [%{id: ^first_id}]} = Purchasing.list_orders(buyer, 73, status: "draft")
      assert {:ok, [_, _]} = Purchasing.list_orders(buyer, 73, supplier_id: context.supplier.id)
      assert {:ok, []} = Purchasing.list_orders(buyer, 73, supplier_id: context.supplier.id + 1)
      assert {:ok, [_]} = Purchasing.list_orders(buyer, 73, limit: 1)

      for option <- [[limit: 0], [limit: 501], [limit: "1"], [status: "lost"], [supplier_id: "x"]] do
        assert {:error, :invalid_option} = Purchasing.list_orders(buyer, 73, option)
      end

      assert {:error, :order_not_found} = Purchasing.get_order(buyer, 73, "1")
      assert {:error, :order_not_found} = Purchasing.find_order_by_number(buyer, 73, 99)
      assert {:error, :line_not_found} = Purchasing.get_order_line(buyer, 73, 0)

      viewer = TestFixtures.sign_in!(context.first_scope, 73, 96, [@view])
      [line | _] = first.lines

      assert {:ok,
              %{id: line_id, order_id: order_id, currency_code: "XTS", supplier_id: supplier_id}} =
               Purchasing.get_order_line(viewer, 73, line.id)

      assert {line_id, order_id, supplier_id} == {line.id, first.id, context.supplier.id}
    end
  end
end
