defmodule Bilimbi.SupplyChain.Receiving do
  @moduledoc """
  A company's goods receipts against its purchase orders: what arrived,
  what was accepted and what was rejected and why, posted against the order
  so a supplier's bill can be matched to what was ordered and received.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize
  `supply-chain.receiving.view` and writes their own capability for the
  scope's signed-in actor and the target company at the moment they run,
  through `Bilimbi.Core.Company.authorize_company_target/3`; a write then
  holds `Bilimbi.Core.Company.lock_writable_company/2` for its transaction.
  Orders are read, and their received quantities changed, only through
  `Bilimbi.SupplyChain.Purchasing`'s facade with the same scope, so the
  actor also needs `supply-chain.purchasing.view` to receive against an
  order and `supply-chain.purchasing.orders.receive` to post or reverse.

  The database numbers each company's receipts 1, 2, 3, ... in creation
  order, so a number is never skipped or reused: a cancelled draft keeps
  its number. Every creation and status transition writes a history row
  naming the actor (and any impersonator), the time the database recorded
  it, and the reason given; the database refuses a transition without one.
  A draft is free to change. A posted receipt is fixed for good and is
  corrected only by `reverse_receipt/4`, which posts a reversal receipt
  naming it; the reversal takes the accepted quantities back off the order.

  Over-receipt is refused: a line's accepted quantity, added to what the
  order line already received, may not exceed the ordered quantity by more
  than the company's configured tolerance (`configure/3`, default none).

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Receiving.{Receipt, ReceiptEvent, ReceiptLine, Setting}
  alias Ecto.Changeset

  @view "supply-chain.receiving.view"
  @configure "supply-chain.receiving.configuration.manage"
  @manage "supply-chain.receiving.receipts.manage"
  @post "supply-chain.receiving.receipts.post-receipt"

  @default_limit 100
  @max_limit 500
  @hundred Decimal.new(100)

  @receivable_statuses ~w(sent partially_received)

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived
  @type transition_refusal :: {:invalid_transition, String.t(), String.t()}
  @type order_refusal :: :order_not_found | {:order_not_receivable, String.t()}

  @doc "The capability every receiving read asks for."
  def view_capability, do: @view

  @doc "The capability that sets the company's over-receipt tolerance."
  def configure_capability, do: @configure

  @doc "The capability that drafts, changes, and cancels goods receipts."
  def manage_receipts_capability, do: @manage

  @doc "The capability that posts a goods receipt or reverses a posted one."
  def post_receipts_capability, do: @post

  @doc "The statuses a goods receipt moves through."
  @spec receipt_statuses() :: [String.t()]
  def receipt_statuses, do: Receipt.statuses()

  @doc "The kinds of goods receipt: `receipt`, or the `reversal` of one."
  @spec receipt_kinds() :: [String.t()]
  def receipt_kinds, do: Receipt.kinds()

  @doc "The order statuses goods are received against."
  @spec receivable_order_statuses() :: [String.t()]
  def receivable_order_statuses, do: @receivable_statuses

  ## Settings

  @doc """
  The company's current receiving settings: `over_receipt_tolerance_percent`
  (zero until configured), and who set it and when.
  """
  @spec get_settings(Scope.t(), term()) :: {:ok, map()} | {:error, refusal()}
  def get_settings(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, settings_view(current_setting(scope, company_id))}
    end
  end

  @doc """
  Sets the company's over-receipt tolerance: `over_receipt_tolerance_percent`
  from 0 to 100 with up to four decimal places. Each change is a new
  settings row; earlier ones stay as history.
  """
  @spec configure(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def configure(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @configure, fn ->
      actor = actor(scope)

      %Setting{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        set_by_user_id: actor.user_id,
        set_by_impersonator_id: actor.impersonator_id
      }
      |> Setting.changeset(attributes)
      |> Repo.insert()
      |> public_result(&settings_view/1)
    end)
  end

  ## Receipts

  @doc """
  The company's goods receipts with their lines, newest number first.
  Options: `status` (one of `receipt_statuses/0`), `order_id`, and `limit`
  (1 to #{@max_limit}, default #{@default_limit}). A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec list_receipts(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_receipts(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, limit, status} <- list_options(options),
         {:ok, order_id} <- positive_option(options, :order_id) do
      receipts =
        scope
        |> receipts_query(company_id)
        |> status_filter(status)
        |> order_filter(order_id)
        |> order_by([r], desc: r.receipt_number)
        |> limit(^limit)
        |> preload(:lines)
        |> Repo.all()

      {:ok, views(scope, company_id, receipts)}
    end
  end

  @doc """
  One goods receipt: its header, lines, status history (oldest first), and
  the receipt it reverses or the reversal that corrected it.
  """
  @spec get_receipt(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :receipt_not_found}
  def get_receipt(%Scope{} = scope, company_id, receipt_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case receipt_with_lines(scope, company_id, receipt_id) do
        nil -> {:error, :receipt_not_found}
        receipt -> {:ok, full_view(scope, receipt)}
      end
    end
  end

  @doc "The receipt with this `receipt_number` in the company, as `get_receipt/3` returns it."
  @spec find_receipt_by_number(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :receipt_not_found}
  def find_receipt_by_number(%Scope{} = scope, company_id, receipt_number) do
    with :ok <- authorize(scope, company_id, @view) do
      query =
        if is_integer(receipt_number),
          do: where(receipts_query(scope, company_id), [r], r.receipt_number == ^receipt_number),
          else: where(receipts_query(scope, company_id), false)

      case query |> preload(:lines) |> Repo.one() do
        nil -> {:error, :receipt_not_found}
        receipt -> {:ok, full_view(scope, receipt)}
      end
    end
  end

  @doc """
  Drafts a goods receipt against a sent or partially received order:
  `order_id`, `received_on` (default today), optionally
  `supplier_reference` (the delivery note) and `notes`, and `lines` (at
  least one), each `%{order_line_id, received_quantity, rejected_quantity,
  rejection_reason}` naming a current line of the order once. The accepted
  (`received_quantity`) and rejected quantities default to zero and are not
  both zero; a rejection carries its reason. Each line copies the order
  line's number, description, unit, and ordered quantity. An order in any
  other status is `{:error, {:order_not_receivable, status}}`.
  """
  @spec create_receipt(Scope.t(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | order_refusal() | :no_lines | Changeset.t()}
  def create_receipt(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage, fn ->
      with {:ok, order} <- receivable_order(scope, company_id, fetch(attributes, :order_id)),
           {:ok, lines} <- given_lines(attributes),
           tolerance = tolerance(scope, company_id),
           {:ok, changesets} <- line_changesets(scope, company_id, order, lines, tolerance) do
        actor = actor(scope)

        %Receipt{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          order_id: order.id,
          order_number: order.order_number,
          supplier_id: order.supplier_id,
          received_on: Date.utc_today(),
          created_by_user_id: actor.user_id,
          created_by_impersonator_id: actor.impersonator_id
        }
        |> Receipt.changeset(attributes)
        |> Changeset.put_assoc(:lines, changesets)
        |> Repo.insert()
        |> record_event(scope, nil, nil)
        |> public_result(&full_view(scope, reload(scope, &1)))
      end
    end)
  end

  @doc """
  Changes a draft's `received_on`, `supplier_reference`, or `notes`, and
  replaces its lines when `lines` is given. A receipt that is no longer a
  draft is `{:error, {:invalid_transition, status, "draft"}}`.
  """
  @spec update_receipt(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :receipt_not_found
             | order_refusal()
             | :no_lines
             | transition_refusal()
             | Changeset.t()}
  def update_receipt(%Scope{} = scope, company_id, receipt_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage, fn ->
      with {:ok, receipt} <- locked_receipt(scope, company_id, receipt_id),
           :ok <- require_status(receipt, "draft", "draft"),
           {:ok, changeset} <- replace_lines(scope, receipt, attributes) do
        changeset
        |> Repo.update()
        |> public_result(&full_view(scope, reload(scope, &1)))
      end
    end)
  end

  @doc "Cancels a draft that will not be posted; a `reason` is required. It keeps its number."
  @spec cancel_receipt(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :receipt_not_found | transition_refusal() | Changeset.t()}
  def cancel_receipt(%Scope{} = scope, company_id, receipt_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage, fn ->
      with {:ok, receipt} <- locked_receipt(scope, company_id, receipt_id),
           :ok <- require_status(receipt, "draft", "cancelled"),
           {:ok, reason} <- required_reason(attributes) do
        transition(scope, receipt, "cancelled", reason, cancelled_at: DateTime.utc_now())
      end
    end)
  end

  @doc """
  Posts a draft: its lines take the order lines' current description, unit,
  and ordered quantity, the accepted quantities are recorded on the order
  through `Bilimbi.SupplyChain.Purchasing.record_receipt/4` with the
  company's tolerance, and the receipt becomes `posted`, fixed for good.
  An order no longer sent or partially received, or a line that is no
  longer a current line of it, refuses the posting; a draft is corrected
  or cancelled instead.
  """
  @spec post_receipt(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :receipt_not_found
             | order_refusal()
             | transition_refusal()
             | Changeset.t()}
  def post_receipt(%Scope{} = scope, company_id, receipt_id) do
    write(scope, company_id, @post, fn ->
      with {:ok, receipt} <- locked_receipt(scope, company_id, receipt_id),
           :ok <- require_status(receipt, "draft", "posted"),
           {:ok, order} <- receivable_order(scope, company_id, receipt.order_id),
           {:ok, lines} <- refresh_lines(receipt, order),
           {:ok, _order} <- record_on_order(scope, company_id, receipt, lines) do
        post(scope, receipt, nil)
      end
    end)
  end

  @doc """
  Reverses a posted receipt: posts a receipt of kind `reversal` that names
  it, with the same lines, dated `received_on` (default today) and carrying
  the `reason` (required), and takes the accepted quantities back off the
  order through `Bilimbi.SupplyChain.Purchasing.reverse_receipt/4`, which
  reopens a closed order. A receipt is reversed once
  (`{:error, :receipt_reversed}`); a reversal is not itself reversed
  (`{:error, :reversal_not_reversible}`): the goods are received again
  with a new receipt.
  """
  @spec reverse_receipt(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :receipt_not_found
             | :receipt_reversed
             | :reversal_not_reversible
             | transition_refusal()
             | Changeset.t()}
  def reverse_receipt(%Scope{} = scope, company_id, receipt_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post, fn ->
      with {:ok, original} <- locked_receipt(scope, company_id, receipt_id),
           :ok <- require_status(original, "posted", "reversed"),
           :ok <- require_reversible(scope, original),
           {:ok, reason} <- required_reason(attributes),
           {:ok, reversal} <- insert_reversal(scope, original, reason, attributes),
           {:ok, _order} <- reverse_on_order(scope, company_id, reversal, reason) do
        post(scope, reversal, reason)
      end
    end)
  end

  ## Seams for other modules

  @doc """
  What the company received against one order, per current or past order
  line, from posted receipts only: `order_line_id`, the line's number,
  description, unit, and ordered quantity as last posted, the net
  `received_quantity` (accepted, less reversals) and `rejected_quantity`,
  and the posted receipts and reversals that make them up. Finance payables
  matches a bill line's quantity against `received_quantity` here and the
  price against `Bilimbi.SupplyChain.Purchasing.get_order_line/3`; the
  billed quantity is Finance's own record.
  """
  @spec order_receipts(Scope.t(), term(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def order_receipts(%Scope{} = scope, company_id, order_id) do
    with :ok <- authorize(scope, company_id, @view) do
      query =
        if is_integer(order_id),
          do: where(posted_lines(scope, company_id), [l, r], r.order_id == ^order_id),
          else: where(posted_lines(scope, company_id), false)

      {:ok, query |> Repo.all() |> line_summaries()}
    end
  end

  @doc """
  What the company received against one order line, as one entry of
  `order_receipts/3`; a line nothing was posted against has zero quantities
  and no receipts.
  """
  @spec order_line_receipts(Scope.t(), term(), term()) :: {:ok, map()} | {:error, refusal()}
  def order_line_receipts(%Scope{} = scope, company_id, order_line_id) do
    with :ok <- authorize(scope, company_id, @view) do
      query =
        if is_integer(order_line_id),
          do: where(posted_lines(scope, company_id), [l], l.order_line_id == ^order_line_id),
          else: where(posted_lines(scope, company_id), false)

      case query |> Repo.all() |> line_summaries() do
        [summary] ->
          {:ok, summary}

        [] ->
          {:ok,
           %{
             order_line_id: order_line_id,
             order_id: nil,
             order_number: nil,
             order_line_number: nil,
             description: nil,
             unit: nil,
             ordered_quantity: nil,
             received_quantity: Decimal.new(0),
             rejected_quantity: Decimal.new(0),
             receipts: []
           }}
      end
    end
  end

  @doc """
  The company's postings in the order they happened, for a module that
  follows goods into stock: each is `%{posting_id, posted_at, receipt}`
  where `receipt` is what `get_receipt/3` returns, a receipt adding its
  accepted lines to stock and a reversal taking them out again. Options:
  `after_posting_id` (the last `posting_id` the caller handled, default 0)
  and `limit` (1 to #{@max_limit}, default #{@default_limit}). Postings are
  never edited or removed, so a caller that keeps its last `posting_id`
  reads each one exactly once; this is the event seam a Factory inventory
  module consumes when it is mounted.
  """
  @spec list_postings(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_postings(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, limit, nil} <- list_options(Keyword.take(options, [:limit])),
         {:ok, after_id} <- positive_option(options, :after_posting_id) do
      events =
        from(e in Tenancy.scope_query(ReceiptEvent, scope),
          where: e.company_id == ^company_id and e.to_status == "posted",
          where: e.id > ^(after_id || 0),
          order_by: [asc: e.id],
          limit: ^limit
        )
        |> Repo.all()

      receipts =
        scope
        |> receipts_query(company_id)
        |> where([r], r.id in ^Enum.map(events, & &1.receipt_id))
        |> preload(:lines)
        |> Repo.all()
        |> then(&views(scope, company_id, &1))
        |> Map.new(&{&1.id, &1})

      {:ok,
       Enum.map(events, fn event ->
         %{
           posting_id: event.id,
           posted_at: event.occurred_at,
           receipt: Map.fetch!(receipts, event.receipt_id)
         }
       end)}
    end
  end

  ## Authorization and writes

  # The actor's current grant and company reach decide every call.
  defp authorize(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, _company} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp write(scope, company_id, capability, fun) do
    with :ok <- authorize(scope, company_id, capability) do
      Repo.transact(fn ->
        case Company.lock_writable_company(scope, company_id) do
          {:ok, _proof} -> fun.()
          {:error, :not_found} -> {:error, :company_not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  # `authorize/3` already refused a scope without a signed-in user.
  defp actor(scope) do
    %Actor{type: :user} = actor = Scope.actor(scope)
    %{user_id: actor.user_id, impersonator_id: actor.impersonator_id}
  end

  defp public_result({:ok, record}, view), do: {:ok, view.(record)}
  defp public_result(error, _view), do: error

  ## Orders, through Purchasing's facade

  # Goods are received against a sent or partially received order the actor
  # may read; the order's current lines are what a receipt line names.
  defp receivable_order(scope, company_id, order_id) do
    case Purchasing.get_order(scope, company_id, integer(order_id)) do
      {:ok, %{status: status} = order} when status in @receivable_statuses -> {:ok, order}
      {:ok, %{status: status}} -> {:error, {:order_not_receivable, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_on_order(scope, company_id, receipt, lines) do
    case receipt_lines_for_order(lines) do
      [] ->
        {:ok, nil}

      order_lines ->
        Purchasing.record_receipt(scope, company_id, receipt.order_id, %{
          lines: order_lines,
          tolerance_percent: tolerance(scope, company_id)
        })
    end
  end

  defp reverse_on_order(scope, company_id, reversal, reason) do
    case receipt_lines_for_order(reversal.lines) do
      [] ->
        {:ok, nil}

      order_lines ->
        Purchasing.reverse_receipt(scope, company_id, reversal.order_id, %{
          lines: order_lines,
          reason: reason
        })
    end
  end

  # Only accepted goods count on the order; rejected ones went back.
  defp receipt_lines_for_order(lines) do
    for line <- lines,
        Decimal.gt?(line.received_quantity, 0),
        do: %{line_id: line.order_line_id, quantity: line.received_quantity}
  end

  ## Lines

  defp given_lines(attributes) do
    case attributes |> fetch(:lines) |> List.wrap() do
      [] -> {:error, :no_lines}
      lines -> {:ok, lines}
    end
  end

  # Each line names a current order line once and copies its facts; a
  # line's accepted quantity stays within the tolerance of what the order
  # line has left to receive.
  defp line_changesets(scope, company_id, order, lines, tolerance) do
    current = Map.new(order.lines, &{&1.id, &1})

    changesets =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} ->
        line = if is_map(line), do: line, else: %{}
        order_line = Map.get(current, line |> fetch(:order_line_id) |> integer())

        %ReceiptLine{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          line_number: number
        }
        |> ReceiptLine.changeset(line, order_line)
        |> within_tolerance(order_line, tolerance)
      end)

    cond do
      duplicate_lines?(changesets) ->
        {:error, lines_refusal(%Receipt{}, "names each order line once")}

      Enum.all?(changesets, & &1.valid?) ->
        {:ok, changesets}

      true ->
        {:error, lines_error(%Receipt{}, changesets)}
    end
  end

  defp within_tolerance(changeset, nil, _tolerance), do: changeset

  defp within_tolerance(changeset, order_line, tolerance) do
    received = Changeset.get_field(changeset, :received_quantity)

    if changeset.valid? and
         Decimal.gt?(
           Decimal.add(order_line.received_quantity, received),
           ceiling(order_line.quantity, tolerance)
         ) do
      message =
        if Decimal.equal?(tolerance, 0),
          do: "exceeds what the order line has left to receive",
          else: "exceeds what the order line has left to receive, beyond the tolerance"

      Changeset.add_error(changeset, :received_quantity, message)
    else
      changeset
    end
  end

  defp ceiling(quantity, tolerance),
    do: quantity |> Decimal.mult(Decimal.add(@hundred, tolerance)) |> Decimal.div(@hundred)

  defp duplicate_lines?(changesets) do
    ids = Enum.map(changesets, &Changeset.get_field(&1, :order_line_id))
    length(ids) != length(Enum.uniq(ids))
  end

  # A draft's lines are replaced whole, against the order as it is now.
  defp replace_lines(scope, receipt, attributes) do
    changeset = Receipt.changeset(receipt, attributes)

    case fetch(attributes, :lines) do
      nil ->
        {:ok, changeset}

      lines ->
        with {:ok, lines} <- given_lines(%{lines: lines}),
             {:ok, order} <- receivable_order(scope, receipt.company_id, receipt.order_id),
             tolerance = tolerance(scope, receipt.company_id),
             {:ok, line_changesets} <-
               line_changesets(scope, receipt.company_id, order, lines, tolerance) do
          {_count, nil} =
            Repo.delete_all(
              from(l in Tenancy.scope_query(ReceiptLine, scope),
                where: l.id in ^Enum.map(receipt.lines, & &1.id)
              )
            )

          {:ok,
           changeset
           |> Map.put(:data, %{receipt | lines: []})
           |> Changeset.put_assoc(:lines, line_changesets)}
        end
    end
  end

  # At posting each line takes the order line's current facts, so the
  # posted receipt reads what was ordered when the goods were booked in.
  defp refresh_lines(receipt, order) do
    current = Map.new(order.lines, &{&1.id, &1})

    changesets =
      Enum.map(receipt.lines, fn line ->
        ReceiptLine.changeset(line, %{}, Map.get(current, line.order_line_id))
      end)

    if Enum.all?(changesets, & &1.valid?) do
      changesets
      |> Enum.reduce_while({:ok, []}, fn changeset, {:ok, lines} ->
        case Repo.update(changeset) do
          {:ok, line} -> {:cont, {:ok, [line | lines]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
      |> case do
        {:ok, lines} -> {:ok, Enum.reverse(lines)}
        error -> error
      end
    else
      {:error, lines_error(receipt, changesets)}
    end
  end

  # An invalid changeset carrying each line's errors under `lines`. The
  # lines are detached from their rows so the parent reports them as new.
  defp lines_error(receipt, changesets) do
    detached =
      Enum.map(changesets, fn changeset ->
        %{changeset | data: struct(changeset.data.__struct__), action: nil}
      end)

    %{receipt | lines: []}
    |> Changeset.change()
    |> Changeset.put_assoc(:lines, detached)
    |> Map.put(:valid?, false)
  end

  defp lines_refusal(receipt, message) do
    %{receipt | lines: []} |> Changeset.change() |> Changeset.add_error(:lines, message)
  end

  ## Reversals

  defp require_reversible(_scope, %Receipt{kind: "reversal"}),
    do: {:error, :reversal_not_reversible}

  defp require_reversible(scope, %Receipt{} = original) do
    if Map.has_key?(
         reversals_by_original(scope, original.company_id, [original.id]),
         original.id
       ),
       do: {:error, :receipt_reversed},
       else: :ok
  end

  defp insert_reversal(scope, original, reason, attributes) do
    actor = actor(scope)

    lines =
      Enum.map(original.lines, fn line ->
        %ReceiptLine{
          tenant_id: line.tenant_id,
          company_id: line.company_id,
          line_number: line.line_number,
          order_line_id: line.order_line_id,
          order_line_number: line.order_line_number,
          description: line.description,
          unit: line.unit,
          ordered_quantity: line.ordered_quantity,
          received_quantity: line.received_quantity,
          rejected_quantity: line.rejected_quantity,
          rejection_reason: line.rejection_reason
        }
      end)

    %Receipt{
      tenant_id: original.tenant_id,
      company_id: original.company_id,
      kind: "reversal",
      order_id: original.order_id,
      order_number: original.order_number,
      supplier_id: original.supplier_id,
      reverses_receipt_id: original.id,
      reason: reason,
      received_on: Date.utc_today(),
      supplier_reference: original.supplier_reference,
      created_by_user_id: actor.user_id,
      created_by_impersonator_id: actor.impersonator_id
    }
    |> Receipt.changeset(Map.drop(attributes, [:supplier_reference, "supplier_reference"]))
    |> Changeset.put_assoc(:lines, lines)
    |> Repo.insert()
    |> record_event(scope, nil, nil)
  end

  ## Transitions

  defp post(scope, receipt, reason) do
    actor = actor(scope)

    transition(scope, receipt, "posted", reason,
      posted_by_user_id: actor.user_id,
      posted_by_impersonator_id: actor.impersonator_id,
      posted_at: DateTime.utc_now()
    )
  end

  defp transition(scope, receipt, status, reason, changes) do
    from = receipt.status

    receipt
    |> Receipt.transition_changeset(status, changes)
    |> Repo.update()
    |> record_event(scope, from, reason)
    |> public_result(&full_view(scope, reload(scope, &1)))
  end

  defp record_event({:ok, receipt}, scope, from, reason) do
    actor = actor(scope)

    with {:ok, _event} <-
           Repo.insert(%ReceiptEvent{
             tenant_id: receipt.tenant_id,
             company_id: receipt.company_id,
             receipt_id: receipt.id,
             from_status: from,
             to_status: receipt.status,
             actor_user_id: actor.user_id,
             actor_impersonator_id: actor.impersonator_id,
             reason: reason
           }) do
      {:ok, receipt}
    end
  end

  defp record_event(error, _scope, _from, _reason), do: error

  ## Validation helpers

  defp require_status(%{status: status}, allowed, _target) when status == allowed, do: :ok

  defp require_status(%{status: status}, _allowed, target),
    do: {:error, {:invalid_transition, status, target}}

  defp required_reason(attributes) do
    case fetch(attributes, :reason) do
      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> reason_error("can't be blank")
          trimmed -> bounded_reason(trimmed)
        end

      nil ->
        reason_error("can't be blank")

      _other ->
        reason_error("is invalid")
    end
  end

  defp bounded_reason(reason) do
    if length(String.codepoints(reason)) > 500,
      do: reason_error("should be at most 500 character(s)"),
      else: {:ok, reason}
  end

  defp reason_error(message) do
    {:error,
     {%{}, %{reason: :string}}
     |> Changeset.cast(%{}, [])
     |> Changeset.add_error(:reason, message)}
  end

  defp list_options(options) do
    limit = Keyword.get(options, :limit, @default_limit)
    status = Keyword.get(options, :status)

    if is_integer(limit) and limit in 1..@max_limit and
         (is_nil(status) or status in Receipt.statuses()),
       do: {:ok, limit, status},
       else: {:error, :invalid_option}
  end

  defp positive_option(options, key) do
    case Keyword.get(options, key) do
      nil -> {:ok, nil}
      id when is_integer(id) and id > 0 -> {:ok, id}
      _other -> {:error, :invalid_option}
    end
  end

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  ## Queries

  defp receipts_query(scope, company_id),
    do: from(r in Tenancy.scope_query(Receipt, scope), where: r.company_id == ^company_id)

  defp settings_query(scope, company_id),
    do: from(s in Tenancy.scope_query(Setting, scope), where: s.company_id == ^company_id)

  defp current_setting(scope, company_id) do
    scope
    |> settings_query(company_id)
    |> order_by([s], desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  defp tolerance(scope, company_id) do
    case current_setting(scope, company_id) do
      nil -> Decimal.new(0)
      setting -> setting.over_receipt_tolerance_percent
    end
  end

  defp locked_receipt(scope, company_id, receipt_id) when is_integer(receipt_id) do
    case scope
         |> receipts_query(company_id)
         |> where([r], r.id == ^receipt_id)
         |> lock("FOR UPDATE")
         |> preload(:lines)
         |> Repo.one() do
      nil -> {:error, :receipt_not_found}
      receipt -> {:ok, receipt}
    end
  end

  defp locked_receipt(_scope, _company_id, _receipt_id), do: {:error, :receipt_not_found}

  defp receipt_with_lines(scope, company_id, receipt_id) when is_integer(receipt_id) do
    scope
    |> receipts_query(company_id)
    |> where([r], r.id == ^receipt_id)
    |> preload(:lines)
    |> Repo.one()
  end

  defp receipt_with_lines(_scope, _company_id, _receipt_id), do: nil

  defp reload(scope, receipt), do: receipt_with_lines(scope, receipt.company_id, receipt.id)

  # Posted lines joined to their receipts, oldest posting first.
  defp posted_lines(scope, company_id) do
    from(l in Tenancy.scope_query(ReceiptLine, scope),
      join: r in ^receipts_query(scope, company_id),
      on: r.id == l.receipt_id,
      where: r.status == "posted",
      order_by: [asc: l.order_line_id, asc: r.posted_at, asc: r.id],
      select: {l, r}
    )
  end

  # A posted reversal per original receipt, as `original_id => reversal`.
  defp reversals_by_original(_scope, _company_id, []), do: %{}

  defp reversals_by_original(scope, company_id, ids) do
    scope
    |> receipts_query(company_id)
    |> where([r], r.reverses_receipt_id in ^ids and r.status == "posted")
    |> Repo.all()
    |> Map.new(&{&1.reverses_receipt_id, &1})
  end

  defp receipt_numbers(_scope, _company_id, []), do: %{}

  defp receipt_numbers(scope, company_id, ids) do
    scope
    |> receipts_query(company_id)
    |> where([r], r.id in ^ids)
    |> select([r], {r.id, r.receipt_number})
    |> Repo.all()
    |> Map.new()
  end

  defp status_filter(query, nil), do: query
  defp status_filter(query, status), do: where(query, [r], r.status == ^status)

  defp order_filter(query, nil), do: query
  defp order_filter(query, order_id), do: where(query, [r], r.order_id == ^order_id)

  ## Views

  defp full_view(scope, receipt) do
    events =
      from(e in Tenancy.scope_query(ReceiptEvent, scope),
        where: e.company_id == ^receipt.company_id and e.receipt_id == ^receipt.id,
        order_by: [asc: e.id]
      )
      |> Repo.all()
      |> Enum.map(&event_view/1)

    [view] = views(scope, receipt.company_id, [receipt])
    Map.put(view, :events, events)
  end

  # The receipt views with the reversal links resolved in two queries for
  # the whole list; the single read adds the history afterwards.
  defp views(scope, company_id, receipts) do
    ids = Enum.map(receipts, & &1.id)
    reversals = reversals_by_original(scope, company_id, ids)

    numbers =
      receipt_numbers(
        scope,
        company_id,
        Enum.uniq(
          Enum.map(Map.values(reversals), & &1.id) ++
            for(r <- receipts, r.reverses_receipt_id, do: r.reverses_receipt_id)
        )
      )

    Enum.map(receipts, fn receipt ->
      reversal = Map.get(reversals, receipt.id)

      receipt
      |> Map.take([
        :id,
        :receipt_number,
        :kind,
        :status,
        :order_id,
        :order_number,
        :supplier_id,
        :reverses_receipt_id,
        :reason,
        :received_on,
        :supplier_reference,
        :notes,
        :created_by_user_id,
        :created_by_impersonator_id,
        :posted_by_user_id,
        :posted_by_impersonator_id,
        :posted_at,
        :cancelled_at,
        :inserted_at,
        :updated_at
      ])
      |> Map.merge(%{
        reverses_receipt_number: Map.get(numbers, receipt.reverses_receipt_id),
        reversed_by_receipt_id: reversal && reversal.id,
        reversed_by_receipt_number: reversal && Map.get(numbers, reversal.id),
        lines: Enum.map(receipt.lines, &line_view/1),
        events: []
      })
    end)
  end

  defp line_view(line) do
    Map.take(line, [
      :id,
      :line_number,
      :order_line_id,
      :order_line_number,
      :description,
      :unit,
      :ordered_quantity,
      :received_quantity,
      :rejected_quantity,
      :rejection_reason
    ])
  end

  defp event_view(event) do
    Map.take(event, [
      :id,
      :from_status,
      :to_status,
      :actor_user_id,
      :actor_impersonator_id,
      :reason,
      :occurred_at
    ])
  end

  defp settings_view(nil) do
    %{
      over_receipt_tolerance_percent: Decimal.new(0),
      set_by_user_id: nil,
      set_by_impersonator_id: nil,
      occurred_at: nil
    }
  end

  defp settings_view(setting) do
    Map.take(setting, [
      :over_receipt_tolerance_percent,
      :set_by_user_id,
      :set_by_impersonator_id,
      :occurred_at
    ])
  end

  # Net quantities per order line from posted lines: a receipt adds, a
  # reversal subtracts. The last posted line gives the order facts.
  defp line_summaries(rows) do
    rows
    |> Enum.group_by(fn {line, _receipt} -> line.order_line_id end)
    |> Enum.map(fn {order_line_id, pairs} ->
      {last_line, last_receipt} = List.last(pairs)

      receipts =
        Enum.map(pairs, fn {line, receipt} ->
          %{
            receipt_id: receipt.id,
            receipt_number: receipt.receipt_number,
            kind: receipt.kind,
            reverses_receipt_id: receipt.reverses_receipt_id,
            received_on: receipt.received_on,
            posted_at: receipt.posted_at,
            received_quantity: line.received_quantity,
            rejected_quantity: line.rejected_quantity,
            rejection_reason: line.rejection_reason
          }
        end)

      %{
        order_line_id: order_line_id,
        order_id: last_receipt.order_id,
        order_number: last_receipt.order_number,
        order_line_number: last_line.order_line_number,
        description: last_line.description,
        unit: last_line.unit,
        ordered_quantity: last_line.ordered_quantity,
        received_quantity: net(pairs, :received_quantity),
        rejected_quantity: net(pairs, :rejected_quantity),
        receipts: receipts
      }
    end)
    |> Enum.sort_by(&{&1.order_number, &1.order_line_number, &1.order_line_id})
  end

  defp net(pairs, field) do
    Enum.reduce(pairs, Decimal.new(0), fn {line, receipt}, sum ->
      case receipt.kind do
        "receipt" -> Decimal.add(sum, Map.fetch!(line, field))
        "reversal" -> Decimal.sub(sum, Map.fetch!(line, field))
      end
    end)
  end
end
