defmodule Bilimbi.SupplyChain.Receiving.ReceiptsTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.TestFixtures, as: PurchasingFixtures
  alias Bilimbi.SupplyChain.Receiving
  alias Bilimbi.SupplyChain.Receiving.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "supply-chain.receiving.view"
  @configure "supply-chain.receiving.configuration.manage"
  @manage "supply-chain.receiving.receipts.manage"
  @post "supply-chain.receiving.receipts.post-receipt"

  @purchasing_view "supply-chain.purchasing.view"
  @purchasing_configure "supply-chain.purchasing.configuration.manage"
  @purchasing_manage "supply-chain.purchasing.orders.manage"
  @purchasing_approve "supply-chain.purchasing.orders.approve"
  @purchasing_receive "supply-chain.purchasing.orders.receive"

  setup do
    context = TestFixtures.setup_receiving!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    system = context.first_scope

    buyer =
      TestFixtures.sign_in!(system, 73, 91, [
        @purchasing_view,
        @purchasing_configure,
        @purchasing_manage
      ])

    approver = TestFixtures.sign_in!(system, 73, 92, [@purchasing_view, @purchasing_approve])

    # The storekeeper receives: every receiving capability plus the
    # purchasing ones a receiving actor needs.
    keeper =
      TestFixtures.sign_in!(
        system,
        73,
        93,
        TestFixtures.all_capabilities() ++ TestFixtures.purchasing_capabilities()
      )

    order =
      TestFixtures.sent_order!(buyer, approver, 73, [
        PurchasingFixtures.line(%{description: "Bolts", quantity: "10", unit: "box"}),
        PurchasingFixtures.line(%{description: "Nuts", quantity: "5", unit: "bag"})
      ])

    [bolts, nuts] = order.lines

    Map.merge(context, %{
      buyer: buyer,
      approver: approver,
      keeper: keeper,
      order: order,
      bolts: bolts,
      nuts: nuts
    })
  end

  defp draft(context, overrides \\ %{}) do
    {:ok, receipt} =
      Receiving.create_receipt(
        context.keeper,
        73,
        Map.merge(
          %{
            order_id: context.order.id,
            received_on: ~D[2026-10-13],
            supplier_reference: "DN-1",
            lines: [
              TestFixtures.line(context.bolts, %{received_quantity: "4"}),
              TestFixtures.line(context.nuts, %{
                received_quantity: "3",
                rejected_quantity: "1",
                rejection_reason: "Torn bag"
              })
            ]
          },
          overrides
        )
      )

    receipt
  end

  defp posted(context, overrides) do
    {:ok, receipt} = Receiving.post_receipt(context.keeper, 73, draft(context, overrides).id)
    receipt
  end

  defp received(context, line_id) do
    {:ok, order} = Purchasing.get_order(context.keeper, 73, context.order.id)
    Enum.find(order.lines, &(&1.id == line_id)).received_quantity
  end

  describe "settings" do
    test "start at no tolerance, change by appending, and keep their history", context do
      %{keeper: keeper} = context

      assert {:ok, %{set_by_user_id: nil, occurred_at: nil} = settings} =
               Receiving.get_settings(keeper, 73)

      assert Decimal.equal?(settings.over_receipt_tolerance_percent, 0)

      assert {:ok, %{set_by_user_id: 93, occurred_at: %DateTime{}} = settings} =
               Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: "2.5"})

      assert Decimal.equal?(settings.over_receipt_tolerance_percent, "2.5")
      assert {:ok, reread} = Receiving.get_settings(keeper, 73)
      assert Decimal.equal?(reread.over_receipt_tolerance_percent, "2.5")

      assert Map.drop(reread, [:over_receipt_tolerance_percent]) ==
               Map.drop(settings, [:over_receipt_tolerance_percent])

      for value <- ["-1", "100.5", "1.00001", ""] do
        assert {:error, changeset} =
                 Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: value})

        assert %{over_receipt_tolerance_percent: [_]} = errors_on(changeset)
      end

      {:ok, _} = Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: "0"})

      assert %{rows: [[2]]} =
               SQL.query!(Repo, "SELECT count(*) FROM supply_chain_receiving_settings", [])

      assert_raise Postgrex.Error, ~r/supply chain receiving keeps/, fn ->
        SQL.query!(
          Repo,
          "UPDATE supply_chain_receiving_settings SET over_receipt_tolerance_percent = 9",
          []
        )
      end

      # A sibling company has its own, and the setting needs its capability.
      sibling = TestFixtures.sign_in!(context.first_scope, 74, 96, [@view])
      assert {:ok, %{set_by_user_id: nil}} = Receiving.get_settings(sibling, 74)
      TestFixtures.revoke!(context.first_scope, 73, 93, @configure)

      assert {:error, :unauthorized} =
               Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: "1"})
    end
  end

  describe "drafting" do
    test "copies the order lines' facts, numbers receipts without gaps, and records the creator",
         context do
      receipt = draft(context)

      assert %{
               receipt_number: 1,
               kind: "receipt",
               status: "draft",
               order_number: 1,
               received_on: ~D[2026-10-13],
               supplier_reference: "DN-1",
               created_by_user_id: 93,
               posted_at: nil,
               reverses_receipt_id: nil,
               reversed_by_receipt_id: nil,
               events: [%{from_status: nil, to_status: "draft", actor_user_id: 93}]
             } = receipt

      assert receipt.order_id == context.order.id
      assert receipt.supplier_id == context.order.supplier_id

      assert [
               %{
                 line_number: 1,
                 order_line_number: 1,
                 description: "Bolts",
                 unit: "box",
                 rejection_reason: nil
               },
               %{line_number: 2, description: "Nuts", unit: "bag", rejection_reason: "Torn bag"}
             ] = receipt.lines

      [bolts, nuts] = receipt.lines
      assert bolts.order_line_id == context.bolts.id
      assert Decimal.equal?(bolts.ordered_quantity, "10")
      assert Decimal.equal?(bolts.received_quantity, "4")
      assert Decimal.equal?(bolts.rejected_quantity, "0")
      assert Decimal.equal?(nuts.rejected_quantity, "1")

      assert {:ok, ^receipt} = Receiving.get_receipt(context.keeper, 73, receipt.id)
      assert {:ok, ^receipt} = Receiving.find_receipt_by_number(context.keeper, 73, 1)

      # Nothing is recorded on the order until the receipt is posted.
      assert Decimal.equal?(received(context, context.bolts.id), 0)

      # A refused creation takes no number; a cancelled draft keeps its.
      assert {:error, _} =
               Receiving.create_receipt(context.keeper, 73, %{
                 order_id: context.order.id,
                 lines: [TestFixtures.line(context.bolts, %{received_quantity: "0"})]
               })

      assert %{receipt_number: 2} = second = draft(context)

      assert {:ok, %{receipt_number: 2, status: "cancelled", cancelled_at: %DateTime{}}} =
               Receiving.cancel_receipt(context.keeper, 73, second.id, %{reason: "Duplicate"})

      assert %{receipt_number: 3} = draft(context)

      {:ok, numbers} = Receiving.list_receipts(context.keeper, 73)
      assert Enum.map(numbers, & &1.receipt_number) == [3, 2, 1]
    end

    test "accepts string keys, as a form sends them, and defaults the date to today", context do
      assert {:ok, %{received_on: today, lines: [%{description: "Bolts"}]}} =
               Receiving.create_receipt(context.keeper, 73, %{
                 "order_id" => Integer.to_string(context.order.id),
                 "lines" => [
                   %{
                     "order_line_id" => Integer.to_string(context.bolts.id),
                     "received_quantity" => "1"
                   }
                 ]
               })

      assert today == Date.utc_today()
    end

    test "refuses an order that is not sent, a line that is not the order's, and bad quantities",
         context do
      %{keeper: keeper, buyer: buyer, approver: approver} = context

      {:ok, other} =
        Purchasing.create_order(buyer, 73, %{
          supplier_id: context.order.supplier_id,
          currency_code: "XTS",
          lines: [PurchasingFixtures.line()]
        })

      {:ok, _} = Purchasing.submit_order(buyer, 73, other.id)
      {:ok, _} = Purchasing.approve_order(approver, 73, other.id, %{})
      [foreign_line] = other.lines

      assert {:error, {:order_not_receivable, "approved"}} =
               Receiving.create_receipt(keeper, 73, %{
                 order_id: other.id,
                 lines: [TestFixtures.line(foreign_line)]
               })

      assert {:error, :order_not_found} =
               Receiving.create_receipt(keeper, 73, %{order_id: 0, lines: [%{}]})

      assert {:error, :no_lines} =
               Receiving.create_receipt(keeper, 73, %{order_id: context.order.id, lines: []})

      assert {:error, changeset} =
               Receiving.create_receipt(keeper, 73, %{
                 order_id: context.order.id,
                 lines: [
                   TestFixtures.line(foreign_line),
                   TestFixtures.line(context.bolts, %{received_quantity: "0"}),
                   TestFixtures.line(context.nuts, %{
                     received_quantity: "1",
                     rejected_quantity: "1"
                   })
                 ]
               })

      assert %{
               lines: [
                 %{order_line_id: ["is not a current line of this order"]},
                 %{received_quantity: ["or the rejected quantity must be greater than 0"]},
                 %{rejection_reason: ["can't be blank when goods are rejected"]}
               ]
             } = errors_on(changeset)

      assert {:error, changeset} =
               Receiving.create_receipt(keeper, 73, %{
                 order_id: context.order.id,
                 lines: [
                   %{order_line_id: context.bolts.id, received_quantity: "1.00001"},
                   TestFixtures.line(context.nuts, %{
                     received_quantity: "1",
                     rejection_reason: "x"
                   })
                 ]
               })

      assert %{
               lines: [
                 %{received_quantity: ["has more than 4 decimal places"]},
                 %{rejection_reason: ["applies only to rejected goods"]}
               ]
             } = errors_on(changeset)

      assert {:error, changeset} =
               Receiving.create_receipt(keeper, 73, %{
                 order_id: context.order.id,
                 lines: [TestFixtures.line(context.bolts), TestFixtures.line(context.bolts)]
               })

      assert %{lines: ["names each order line once"]} = errors_on(changeset)

      assert {:error, changeset} =
               Receiving.create_receipt(keeper, 73, %{
                 order_id: context.order.id,
                 received_on: "not a date",
                 lines: [TestFixtures.line(context.bolts)]
               })

      assert %{received_on: [_]} = errors_on(changeset)

      # More than the order line has left is refused up front, not only at posting.
      assert {:error, changeset} =
               Receiving.create_receipt(keeper, 73, %{
                 order_id: context.order.id,
                 lines: [TestFixtures.line(context.bolts, %{received_quantity: "11"})]
               })

      assert %{lines: [%{received_quantity: ["exceeds what the order line has left to receive"]}]} =
               errors_on(changeset)
    end

    test "changes a draft's facts and lines, and nothing once it is posted or cancelled",
         context do
      %{keeper: keeper} = context
      receipt = draft(context)

      assert {:ok, %{notes: "Partial delivery", lines: [%{description: "Nuts"} = nuts]}} =
               Receiving.update_receipt(keeper, 73, receipt.id, %{
                 notes: "Partial delivery",
                 lines: [TestFixtures.line(context.nuts, %{received_quantity: "2"})]
               })

      assert Decimal.equal?(nuts.received_quantity, "2")

      assert {:error, :no_lines} =
               Receiving.update_receipt(keeper, 73, receipt.id, %{lines: []})

      assert {:error, changeset} =
               Receiving.cancel_receipt(keeper, 73, receipt.id, %{reason: "  "})

      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      {:ok, _} = Receiving.post_receipt(keeper, 73, receipt.id)

      assert {:error, {:invalid_transition, "posted", "draft"}} =
               Receiving.update_receipt(keeper, 73, receipt.id, %{notes: "x"})

      assert {:error, {:invalid_transition, "posted", "cancelled"}} =
               Receiving.cancel_receipt(keeper, 73, receipt.id, %{reason: "x"})

      assert {:error, {:invalid_transition, "posted", "posted"}} =
               Receiving.post_receipt(keeper, 73, receipt.id)

      cancelled = draft(context)
      {:ok, _} = Receiving.cancel_receipt(keeper, 73, cancelled.id, %{reason: "Never arrived"})

      assert {:error, {:invalid_transition, "cancelled", "posted"}} =
               Receiving.post_receipt(keeper, 73, cancelled.id)
    end
  end

  describe "posting" do
    test "records accepted goods on the order, which closes when every line is in, and fixes the receipt",
         context do
      %{keeper: keeper, bolts: bolts, nuts: nuts} = context
      receipt = draft(context)

      assert {:ok, posted} = Receiving.post_receipt(keeper, 73, receipt.id)

      assert %{
               status: "posted",
               posted_by_user_id: 93,
               posted_at: %DateTime{},
               events: [%{to_status: "draft"}, %{from_status: "draft", to_status: "posted"}]
             } = posted

      assert Decimal.equal?(received(context, bolts.id), "4")
      assert Decimal.equal?(received(context, nuts.id), "3")

      assert {:ok, %{status: "partially_received"}} =
               Purchasing.get_order(keeper, 73, context.order.id)

      # The rest, rejecting nothing, closes the order.
      late = draft(context, %{lines: [TestFixtures.line(bolts, %{received_quantity: "1"})]})

      posted(context, %{
        lines: [
          TestFixtures.line(bolts, %{received_quantity: "6"}),
          TestFixtures.line(nuts, %{received_quantity: "2"})
        ]
      })

      assert {:ok, %{status: "closed"}} = Purchasing.get_order(keeper, 73, context.order.id)

      # A closed order takes no further receipt; the draft stays a draft.
      assert {:error, {:order_not_receivable, "closed"}} =
               Receiving.post_receipt(keeper, 73, late.id)

      assert {:ok, %{status: "draft"}} = Receiving.get_receipt(keeper, 73, late.id)

      # The posted receipt and its lines are fixed in the database.
      for sql <- [
            "UPDATE supply_chain_receiving_receipts SET notes = 'x' WHERE id = #{posted.id}",
            "UPDATE supply_chain_receiving_receipts SET status = 'draft', posted_by_user_id = NULL, posted_at = NULL WHERE id = #{posted.id}",
            "UPDATE supply_chain_receiving_receipt_lines SET received_quantity = 9 WHERE receipt_id = #{posted.id}",
            "DELETE FROM supply_chain_receiving_receipt_lines WHERE receipt_id = #{posted.id}"
          ] do
        assert_raise Postgrex.Error,
                     ~r/is fixed|does not go from posted|its lines are fixed/,
                     fn ->
                       SQL.query!(Repo, sql, [])
                     end
      end

      for sql <- [
            "DELETE FROM supply_chain_receiving_receipts WHERE id = #{late.id}",
            "TRUNCATE supply_chain_receiving_receipt_events",
            "UPDATE supply_chain_receiving_receipt_events SET reason = 'x'",
            "DELETE FROM supply_chain_receiving_receipt_events"
          ] do
        assert_raise Postgrex.Error, ~r/supply chain receiving keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end
    end

    test "refuses more than the order line has left unless the tolerance allows it", context do
      %{keeper: keeper, bolts: bolts} = context
      posted(context, %{lines: [TestFixtures.line(bolts, %{received_quantity: "8"})]})

      # 8 of 10 received; 3 more would be 11.
      over = draft(context, %{lines: [TestFixtures.line(bolts, %{received_quantity: "2"})]})

      {:ok, _} =
        Receiving.update_receipt(keeper, 73, over.id, %{
          lines: [TestFixtures.line(bolts, %{received_quantity: "2"})]
        })

      assert {:error, changeset} =
               Receiving.update_receipt(keeper, 73, over.id, %{
                 lines: [TestFixtures.line(bolts, %{received_quantity: "3"})]
               })

      assert %{lines: [%{received_quantity: ["exceeds what the order line has left to receive"]}]} =
               errors_on(changeset)

      # A tolerance set after drafting applies at posting, and the order
      # closes on the over-received line.
      {:ok, _} = Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: "10"})

      {:ok, %{lines: [line]}} =
        Receiving.update_receipt(keeper, 73, over.id, %{
          lines: [TestFixtures.line(bolts, %{received_quantity: "3"})]
        })

      assert Decimal.equal?(line.received_quantity, "3")

      assert {:error, changeset} =
               Receiving.update_receipt(keeper, 73, over.id, %{
                 lines: [TestFixtures.line(bolts, %{received_quantity: "3.0001"})]
               })

      assert %{
               lines: [
                 %{
                   received_quantity: [
                     "exceeds what the order line has left to receive, beyond the tolerance"
                   ]
                 }
               ]
             } = errors_on(changeset)

      assert {:ok, %{status: "posted"}} = Receiving.post_receipt(keeper, 73, over.id)
      assert Decimal.equal?(received(context, bolts.id), "11")

      # Purchasing holds the same bound: the tolerance drops back to zero
      # and a draft within the old tolerance is refused at posting.
      {:ok, _} = Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: "0"})

      nuts_over =
        draft(context, %{lines: [TestFixtures.line(context.nuts, %{received_quantity: "5"})]})

      {:ok, _} = Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: "50"})

      {:ok, _} =
        Receiving.update_receipt(keeper, 73, nuts_over.id, %{
          lines: [TestFixtures.line(context.nuts, %{received_quantity: "7"})]
        })

      {:ok, _} = Receiving.configure(keeper, 73, %{over_receipt_tolerance_percent: "0"})

      assert {:error, changeset} = Receiving.post_receipt(keeper, 73, nuts_over.id)

      assert %{lines: [%{received_quantity: ["exceeds the ordered quantity"]}]} =
               errors_on(changeset)

      assert {:ok, %{status: "draft"}} = Receiving.get_receipt(keeper, 73, nuts_over.id)
    end

    test "takes the order line's facts as they are when it is posted, and refuses a line amended away",
         context do
      %{keeper: keeper, buyer: buyer, approver: approver, bolts: bolts} = context
      receipt = draft(context, %{lines: [TestFixtures.line(bolts, %{received_quantity: "1"})]})

      # Before anything is received, the buyer amends the sent order: the
      # bolts line is replaced; the draft receipt names a superseded line.
      {:ok, _} =
        Purchasing.amend_order(buyer, 73, context.order.id, %{
          reason: "Bigger boxes",
          lines: [PurchasingFixtures.line(%{description: "Bolts", quantity: "12", unit: "box"})]
        })

      {:ok, _} = Purchasing.approve_order(approver, 73, context.order.id, %{})
      {:ok, amended} = Purchasing.send_order(buyer, 73, context.order.id)

      assert {:error, changeset} = Receiving.post_receipt(keeper, 73, receipt.id)

      assert %{lines: [%{order_line_id: ["is not a current line of this order"]}]} =
               errors_on(changeset)

      [new_bolts] = amended.lines

      {:ok, %{lines: [line]}} =
        Receiving.update_receipt(keeper, 73, receipt.id, %{
          lines: [TestFixtures.line(new_bolts, %{received_quantity: "12"})]
        })

      assert Decimal.equal?(line.ordered_quantity, "12")

      assert {:ok, %{lines: [%{ordered_quantity: twelve}]}} =
               Receiving.post_receipt(keeper, 73, receipt.id)

      assert Decimal.equal?(twelve, "12")
      assert {:ok, %{status: "closed"}} = Purchasing.get_order(keeper, 73, context.order.id)
    end

    test "needs the posting grant here and the receiving grant in purchasing", context do
      %{first_scope: system, keeper: keeper} = context
      receipt = draft(context)

      clerk = TestFixtures.sign_in!(system, 73, 94, [@view, @manage, @purchasing_view])
      assert {:error, :unauthorized} = Receiving.post_receipt(clerk, 73, receipt.id)

      TestFixtures.revoke!(system, 73, 93, @purchasing_receive)
      assert {:error, :unauthorized} = Receiving.post_receipt(keeper, 73, receipt.id)
      assert {:ok, %{status: "draft"}} = Receiving.get_receipt(keeper, 73, receipt.id)

      # A refused posting rolled back: no event, nothing on the order.
      assert %{rows: [[1]]} =
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM supply_chain_receiving_receipt_events WHERE receipt_id = $1",
                 [receipt.id]
               )

      assert Decimal.equal?(received(context, context.bolts.id), 0)
    end

    test "records the operator behind an impersonated session", context do
      %{first_scope: system} = context
      receipt = draft(context)

      TestFixtures.sign_in!(
        system,
        73,
        95,
        TestFixtures.all_capabilities() ++ TestFixtures.purchasing_capabilities()
      )

      impersonating =
        Authentication.sign_in(system, 95, 73,
          impersonator_id: 93,
          impersonation_session_id: "borrowed-session"
        )

      assert {:ok, posted} = Receiving.post_receipt(impersonating, 73, receipt.id)
      assert %{posted_by_user_id: 95, posted_by_impersonator_id: 93} = posted
      assert %{actor_user_id: 95, actor_impersonator_id: 93} = List.last(posted.events)
    end
  end

  describe "reversal" do
    test "posts a reversal that takes the goods back off the order and reopens it", context do
      %{keeper: keeper, bolts: bolts, nuts: nuts} = context

      original =
        posted(context, %{
          lines: [
            TestFixtures.line(bolts, %{received_quantity: "10"}),
            TestFixtures.line(nuts, %{
              received_quantity: "5",
              rejected_quantity: "1",
              rejection_reason: "Torn bag"
            })
          ]
        })

      assert {:ok, %{status: "closed"}} = Purchasing.get_order(keeper, 73, context.order.id)

      assert {:error, changeset} = Receiving.reverse_receipt(keeper, 73, original.id, %{})
      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, reversal} =
               Receiving.reverse_receipt(keeper, 73, original.id, %{
                 reason: "Counted the wrong pallet",
                 received_on: ~D[2026-10-14]
               })

      assert %{
               receipt_number: 2,
               kind: "reversal",
               status: "posted",
               reason: "Counted the wrong pallet",
               received_on: ~D[2026-10-14],
               supplier_reference: "DN-1",
               reverses_receipt_number: 1,
               reversed_by_receipt_id: nil,
               posted_by_user_id: 93,
               events: [
                 %{to_status: "draft", reason: nil},
                 %{from_status: "draft", to_status: "posted", reason: "Counted the wrong pallet"}
               ]
             } = reversal

      assert reversal.reverses_receipt_id == original.id
      assert reversal.order_id == original.order_id

      assert [
               %{description: "Bolts"} = reversed_bolts,
               %{rejection_reason: "Torn bag"} = reversed_nuts
             ] =
               reversal.lines

      assert Decimal.equal?(reversed_bolts.received_quantity, "10")
      assert Decimal.equal?(reversed_nuts.received_quantity, "5")
      assert Decimal.equal?(reversed_nuts.rejected_quantity, "1")

      assert {:ok, %{reversed_by_receipt_id: reversed_by, reversed_by_receipt_number: 2}} =
               Receiving.get_receipt(keeper, 73, original.id)

      assert reversed_by == reversal.id

      assert {:ok, %{status: "partially_received", events: events}} =
               Purchasing.get_order(keeper, 73, context.order.id)

      assert %{
               from_status: "closed",
               to_status: "partially_received",
               reason: "Counted the wrong pallet"
             } =
               List.last(events)

      assert Decimal.equal?(received(context, bolts.id), 0)
      assert Decimal.equal?(received(context, nuts.id), 0)

      # Once only, and never a reversal; a draft is cancelled instead.
      assert {:error, :receipt_reversed} =
               Receiving.reverse_receipt(keeper, 73, original.id, %{reason: "Again"})

      assert {:error, :reversal_not_reversible} =
               Receiving.reverse_receipt(keeper, 73, reversal.id, %{reason: "Undo"})

      assert {:error, {:invalid_transition, "draft", "reversed"}} =
               Receiving.reverse_receipt(keeper, 73, draft(context).id, %{reason: "x"})

      assert_raise Postgrex.Error, ~r/supply_chain_receiving_receipts_reversal_unique/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO supply_chain_receiving_receipts (tenant_id, company_id, receipt_number, kind, order_id, order_number, supplier_id, reverses_receipt_id, reason, received_on, created_by_user_id, inserted_at, updated_at) VALUES (41, 73, 0, 'reversal', $1, 1, $2, $3, 'x', now(), 93, now(), now())",
          [original.order_id, original.supplier_id, original.id]
        )
      end

      # The goods come in again with a new receipt, and a reversal needs
      # the posting grant.
      assert %{receipt_number: 4} =
               posted(context, %{lines: [TestFixtures.line(bolts, %{received_quantity: "10"})]})

      assert Decimal.equal?(received(context, bolts.id), "10")

      clerk =
        TestFixtures.sign_in!(context.first_scope, 73, 94, [@view, @manage, @purchasing_view])

      assert {:error, :unauthorized} =
               Receiving.reverse_receipt(clerk, 73, original.id, %{reason: "x"})
    end

    test "a receipt that accepted nothing reverses without touching the order", context do
      %{keeper: keeper, bolts: bolts} = context

      rejected =
        posted(context, %{
          lines: [
            TestFixtures.line(bolts, %{
              received_quantity: "0",
              rejected_quantity: "10",
              rejection_reason: "Wrong thread"
            })
          ]
        })

      assert {:ok, %{status: "sent"}} = Purchasing.get_order(keeper, 73, context.order.id)

      assert {:ok, %{kind: "reversal", status: "posted"}} =
               Receiving.reverse_receipt(keeper, 73, rejected.id, %{reason: "Logged twice"})

      assert {:ok, %{status: "sent"}} = Purchasing.get_order(keeper, 73, context.order.id)
    end
  end

  describe "seams" do
    test "sum what was received per order line from posted receipts and reversals only",
         context do
      %{keeper: keeper, bolts: bolts, nuts: nuts} = context

      first =
        posted(context, %{
          lines: [
            TestFixtures.line(bolts, %{received_quantity: "4"}),
            TestFixtures.line(nuts, %{
              received_quantity: "3",
              rejected_quantity: "1",
              rejection_reason: "Torn bag"
            })
          ]
        })

      second = posted(context, %{lines: [TestFixtures.line(bolts, %{received_quantity: "2"})]})
      _draft = draft(context, %{lines: [TestFixtures.line(bolts, %{received_quantity: "3"})]})

      {:ok, reversal} =
        Receiving.reverse_receipt(keeper, 73, second.id, %{reason: "Wrong pallet"})

      assert {:ok, [bolts_summary, nuts_summary]} =
               Receiving.order_receipts(keeper, 73, context.order.id)

      assert %{
               order_line_number: 1,
               description: "Bolts",
               unit: "box",
               receipts: [
                 %{kind: "receipt", receipt_number: 1},
                 %{kind: "receipt", receipt_number: 2},
                 %{kind: "reversal", receipt_number: 4, reverses_receipt_id: reversed}
               ]
             } = bolts_summary

      assert reversed == second.id
      assert bolts_summary.order_line_id == bolts.id
      assert bolts_summary.order_id == context.order.id
      assert Decimal.equal?(bolts_summary.ordered_quantity, "10")
      assert Decimal.equal?(bolts_summary.received_quantity, "4")
      assert Decimal.equal?(bolts_summary.rejected_quantity, "0")
      assert Decimal.equal?(nuts_summary.received_quantity, "3")
      assert Decimal.equal?(nuts_summary.rejected_quantity, "1")

      assert {:ok, ^nuts_summary} = Receiving.order_line_receipts(keeper, 73, nuts.id)

      assert {:ok, %{order_id: nil, receipts: [], received_quantity: zero}} =
               Receiving.order_line_receipts(keeper, 73, 0)

      assert Decimal.equal?(zero, 0)
      assert {:ok, []} = Receiving.order_receipts(keeper, 73, 0)

      # Postings read once each, in order, by the last posting handled.
      assert {:ok, postings} = Receiving.list_postings(keeper, 73)

      assert [
               %{receipt: %{id: first_id, kind: "receipt"}},
               %{receipt: %{id: second_id}},
               %{posting_id: last, receipt: %{id: reversal_id, kind: "reversal", lines: [_]}}
             ] = postings

      assert {first_id, second_id, reversal_id} == {first.id, second.id, reversal.id}
      assert Enum.map(postings, & &1.posting_id) == Enum.sort(Enum.map(postings, & &1.posting_id))

      assert {:ok, [%{receipt: %{id: ^reversal_id}}]} =
               Receiving.list_postings(keeper, 73,
                 after_posting_id: Enum.at(postings, 1).posting_id
               )

      assert {:ok, []} = Receiving.list_postings(keeper, 73, after_posting_id: last)
      assert {:ok, [_]} = Receiving.list_postings(keeper, 73, limit: 1)
      assert {:error, :invalid_option} = Receiving.list_postings(keeper, 73, limit: 0)
      assert {:error, :invalid_option} = Receiving.list_postings(keeper, 73, after_posting_id: -1)
    end
  end

  describe "reads and boundaries" do
    test "filter by status and order, page by limit, and refuse a malformed option", context do
      %{keeper: keeper} = context

      first =
        posted(context, %{lines: [TestFixtures.line(context.bolts, %{received_quantity: "1"})]})

      second = draft(context)

      assert {:ok, [%{id: second_id}, %{id: first_id}]} = Receiving.list_receipts(keeper, 73)
      assert {second_id, first_id} == {second.id, first.id}
      assert {:ok, [%{id: ^first_id}]} = Receiving.list_receipts(keeper, 73, status: "posted")
      assert {:ok, [%{id: ^second_id}]} = Receiving.list_receipts(keeper, 73, limit: 1)

      assert {:ok, [_, _]} =
               Receiving.list_receipts(keeper, 73, order_id: context.order.id)

      assert {:ok, []} = Receiving.list_receipts(keeper, 73, order_id: context.order.id + 1)
      assert {:error, :invalid_option} = Receiving.list_receipts(keeper, 73, status: "lost")
      assert {:error, :invalid_option} = Receiving.list_receipts(keeper, 73, limit: 501)
      assert {:error, :invalid_option} = Receiving.list_receipts(keeper, 73, order_id: "1")
      assert {:error, :receipt_not_found} = Receiving.get_receipt(keeper, 73, "1")
      assert {:error, :receipt_not_found} = Receiving.find_receipt_by_number(keeper, 73, 9)
    end

    test "stay inside the company and the tenant, and refuse a scope with nobody signed in",
         context do
      %{first_scope: system, second_scope: other_system, keeper: keeper} = context
      receipt = draft(context)

      # A sibling company with the same grants sees nothing of this one.
      sibling = TestFixtures.sign_in!(system, 74, 96, TestFixtures.all_capabilities())
      assert {:ok, []} = Receiving.list_receipts(sibling, 74)
      assert {:error, :receipt_not_found} = Receiving.get_receipt(sibling, 74, receipt.id)
      assert {:error, :unauthorized} = Receiving.get_receipt(sibling, 73, receipt.id)

      stranger = TestFixtures.sign_in!(other_system, 75, 97, TestFixtures.all_capabilities())
      assert {:error, :company_not_found} = Receiving.get_receipt(stranger, 73, receipt.id)
      assert {:error, :unauthorized} = Receiving.list_receipts(system, 73)

      # A viewer reads and writes nothing.
      viewer = TestFixtures.sign_in!(system, 73, 98, [@view])
      assert {:ok, [_]} = Receiving.list_receipts(viewer, 73)

      assert {:error, :unauthorized} =
               Receiving.create_receipt(viewer, 73, %{order_id: context.order.id, lines: [%{}]})

      assert {:error, :unauthorized} =
               Receiving.cancel_receipt(viewer, 73, receipt.id, %{reason: "x"})

      assert {:error, :unauthorized} = Receiving.post_receipt(viewer, 73, receipt.id)

      assert {:error, :unauthorized} =
               Receiving.reverse_receipt(viewer, 73, receipt.id, %{reason: "x"})

      # A grant revoked after signing in stops the next call.
      TestFixtures.revoke!(system, 73, 93, @post)
      assert {:error, :unauthorized} = Receiving.post_receipt(keeper, 73, receipt.id)
    end

    test "the database refuses a creation or transition without its history row", context do
      %{keeper: keeper} = context
      receipt = draft(context)

      SQL.query!(
        Repo,
        "INSERT INTO supply_chain_receiving_receipts (tenant_id, company_id, receipt_number, order_id, order_number, supplier_id, received_on, created_by_user_id, inserted_at, updated_at) VALUES (41, 73, 0, $1, 1, $2, now(), 93, now(), now())",
        [receipt.order_id, receipt.supplier_id]
      )

      assert_raise Postgrex.Error, ~r/without a history row/, fn ->
        TestFixtures.check_deferred_constraints!()
      end

      assert_raise Postgrex.Error, ~r/a new goods receipt is a draft/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO supply_chain_receiving_receipts (tenant_id, company_id, receipt_number, status, order_id, order_number, supplier_id, received_on, created_by_user_id, posted_by_user_id, posted_at, inserted_at, updated_at) VALUES (41, 73, 0, 'posted', $1, 1, $2, now(), 93, 93, now(), now(), now())",
          [receipt.order_id, receipt.supplier_id]
        )
      end

      assert {:ok, %{status: "draft"}} = Receiving.get_receipt(keeper, 73, receipt.id)
    end
  end
end
