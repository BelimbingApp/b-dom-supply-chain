defmodule Bilimbi.SupplyChain.Purchasing.RequestsTest do
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
  @manage "supply-chain.purchasing.requests.manage"
  @approve "supply-chain.purchasing.requests.approve"
  @manage_orders "supply-chain.purchasing.orders.manage"

  setup do
    context = TestFixtures.setup_purchasing!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    requester =
      TestFixtures.sign_in!(context.first_scope, 73, 91, [
        @view,
        @configure,
        @manage,
        @manage_orders
      ])

    approver = TestFixtures.sign_in!(context.first_scope, 73, 92, [@view, @approve])
    Map.merge(context, %{requester: requester, approver: approver})
  end

  defp draft(context, overrides \\ %{}) do
    {:ok, request} =
      Purchasing.create_request(
        context.requester,
        73,
        Map.merge(
          %{
            title: " Office chairs ",
            justification: "Two new desks",
            needed_on: "2026-11-15",
            lines: [
              %{description: "Chair", quantity: "2", unit: "unit", external_item_ref: "CHAIR-1"},
              %{description: "Mat", quantity: "2", unit: "unit"}
            ]
          },
          overrides
        )
      )

    request
  end

  defp submitted(context) do
    request = draft(context)
    {:ok, request} = Purchasing.submit_request(context.requester, 73, request.id)
    request
  end

  test "a draft stores its lines, is numbered without gaps, and is edited until submitted",
       context do
    %{requester: requester} = context
    request = draft(context)

    assert %{
             request_number: 1,
             status: "draft",
             title: "Office chairs",
             needed_on: ~D[2026-11-15],
             created_by_user_id: 91,
             lines: [%{line_number: 1, external_item_ref: "CHAIR-1"}, %{line_number: 2}],
             events: [%{from_status: nil, to_status: "draft", actor_user_id: 91}]
           } = request

    assert {:ok, ^request} = Purchasing.get_request(requester, 73, request.id)

    assert {:error, changeset} =
             Purchasing.create_request(requester, 73, %{title: "", lines: [%{quantity: "0"}]})

    assert %{title: [_], lines: [%{description: [_], quantity: [_], unit: [_]}]} =
             errors_on(changeset)

    assert %{request_number: 2} = draft(context)

    assert {:ok, %{title: "Desks", lines: [%{description: "Desk"}]}} =
             Purchasing.update_request(requester, 73, request.id, %{
               title: "Desks",
               lines: [%{description: "Desk", quantity: "1", unit: "unit"}]
             })

    assert {:error, :no_lines} =
             draft(context, %{lines: []})
             |> then(&Purchasing.submit_request(requester, 73, &1.id))

    {:ok, _} = Purchasing.submit_request(requester, 73, request.id)

    assert {:error, {:invalid_transition, "submitted", "draft"}} =
             Purchasing.update_request(requester, 73, request.id, %{title: "Late"})

    assert_raise Postgrex.Error, ~r/changes only by a status transition/, fn ->
      SQL.query!(Repo, "UPDATE supply_chain_purchasing_requests SET title = 'x' WHERE id = $1", [
        request.id
      ])
    end

    assert_raise Postgrex.Error, ~r/its lines are fixed/, fn ->
      SQL.query!(
        Repo,
        "DELETE FROM supply_chain_purchasing_request_lines WHERE request_id = $1",
        [request.id]
      )
    end

    assert {:ok, [%{request_number: 3}, %{request_number: 2}, %{request_number: 1}]} =
             Purchasing.list_requests(requester, 73)

    assert {:ok, [%{request_number: 1}]} =
             Purchasing.list_requests(requester, 73, status: "submitted")

    assert {:error, :invalid_option} = Purchasing.list_requests(requester, 73, status: "lost")
  end

  test "approval is by someone else, rejection needs a reason, and every step is audited",
       context do
    %{first_scope: system, requester: requester, approver: approver} = context
    request = submitted(context)

    assert %{status: "submitted", submitted_by_user_id: 91, submitted_at: %DateTime{}} = request
    assert {:error, :unauthorized} = Purchasing.approve_request(requester, 73, request.id, %{})

    self_approver = TestFixtures.sign_in!(system, 73, 91, [@approve])
    assert {:error, :own_request} = Purchasing.approve_request(self_approver, 73, request.id, %{})

    assert {:error, changeset} = Purchasing.reject_request(approver, 73, request.id, %{})
    assert %{reason: ["can't be blank"]} = errors_on(changeset)

    assert {:ok, approved} =
             Purchasing.approve_request(approver, 73, request.id, %{reason: "Fine"})

    assert %{
             status: "approved",
             decided_by_user_id: 92,
             decided_at: %DateTime{},
             decision_reason: "Fine"
           } = approved

    assert Enum.map(approved.events, &{&1.from_status, &1.to_status, &1.actor_user_id, &1.reason}) ==
             [
               {nil, "draft", 91, nil},
               {"draft", "submitted", 91, nil},
               {"submitted", "approved", 92, "Fine"}
             ]

    assert {:error, {:invalid_transition, "approved", "rejected"}} =
             Purchasing.reject_request(approver, 73, request.id, %{reason: "Too late"})

    rejected = submitted(context)

    assert {:ok, %{status: "rejected", decision_reason: "No budget"}} =
             Purchasing.reject_request(approver, 73, rejected.id, %{reason: "No budget"})

    assert {:error, {:invalid_transition, "rejected", "cancelled"}} =
             Purchasing.cancel_request(requester, 73, rejected.id, %{reason: "x"})

    assert {:ok, %{status: "cancelled", events: events}} =
             Purchasing.cancel_request(requester, 73, approved.id, %{reason: "No longer needed"})

    assert %{from_status: "approved", to_status: "cancelled", reason: "No longer needed"} =
             List.last(events)

    assert_raise Postgrex.Error, ~r/does not go from cancelled to draft/, fn ->
      SQL.query!(
        Repo,
        "UPDATE supply_chain_purchasing_requests SET status = 'draft' WHERE id = $1",
        [
          approved.id
        ]
      )
    end

    assert_raise Postgrex.Error, ~r/supply chain purchasing keeps/, fn ->
      SQL.query!(Repo, "DELETE FROM supply_chain_purchasing_request_events", [])
    end
  end

  test "an approved request becomes a draft order carrying its lines and link", context do
    %{requester: requester, approver: approver} = context
    request = submitted(context)

    {:ok, supplier} =
      Purchasing.create_supplier(requester, 73, TestFixtures.supplier_attributes(%{code: "s"}))

    assert {:error, {:invalid_transition, "submitted", "ordered"}} =
             Purchasing.create_order_from_request(requester, 73, request.id, %{
               supplier_id: supplier.id,
               currency_code: "XTS"
             })

    {:ok, _} = Purchasing.approve_request(approver, 73, request.id, %{})

    assert {:ok, order} =
             Purchasing.create_order_from_request(requester, 73, request.id, %{
               supplier_id: supplier.id,
               currency_code: "XTS",
               reference: "From PR"
             })

    assert %{status: "draft", purchase_request_id: request_id, reference: "From PR"} = order
    assert request_id == request.id

    assert [
             %{description: "Chair", external_item_ref: "CHAIR-1", unit_price: zero},
             %{description: "Mat"}
           ] =
             order.lines

    assert Decimal.equal?(zero, 0)

    # A request may be ordered again, for example from a second supplier.
    assert {:ok, %{purchase_request_id: ^request_id, lines: [%{description: "Priced"}]}} =
             Purchasing.create_order_from_request(requester, 73, request.id, %{
               supplier_id: supplier.id,
               currency_code: "XTS",
               lines: [TestFixtures.line(%{description: "Priced"})]
             })

    assert {:error, :request_not_found} =
             Purchasing.create_order_from_request(requester, 73, request.id + 100, %{})
  end

  test "requests belong to one company and reads need the view grant", context do
    %{first_scope: system, requester: requester} = context
    request = draft(context)

    sibling = TestFixtures.sign_in!(system, 74, 93, [@view, @manage])
    assert {:ok, []} = Purchasing.list_requests(sibling, 74)
    assert {:error, :request_not_found} = Purchasing.get_request(sibling, 74, request.id)
    assert {:error, :unauthorized} = Purchasing.get_request(sibling, 73, request.id)
    assert {:error, :unauthorized} = Purchasing.create_request(system, 73, %{title: "x"})
    assert {:error, :company_not_found} = Purchasing.list_requests(requester, 75)
  end
end
