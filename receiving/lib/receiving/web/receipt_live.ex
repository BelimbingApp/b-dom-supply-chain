defmodule Bilimbi.SupplyChain.Receiving.Web.ReceiptLive do
  @moduledoc """
  One goods receipt through the Receiving facade: its header, lines, and
  status history, with the actions its status allows. Viewing needs
  `supply-chain.receiving.view`; cancelling a draft needs
  `supply-chain.receiving.receipts.manage`, posting it or reversing a posted
  receipt needs `supply-chain.receiving.receipts.post-receipt`, and the facade
  checks the capability again when each runs. Every action waits for
  confirmation, because none can be undone from this page.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.SupplyChain.Receiving
  alias Bilimbi.SupplyChain.Receiving.Web.Forms
  alias Bilimbi.SupplyChain.Receiving.Web.Refusals

  @manage "supply-chain.receiving.receipts.manage"
  @post "supply-chain.receiving.receipts.post-receipt"
  @write_events ~w(transition confirm)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "supply_chain.receipts")
     |> assign(:receipt_id, Forms.integer(id))
     |> assign(:can_manage?, can?(socket, @manage))
     |> assign(:can_post?, can?(socket, @post))
     |> assign(:pending, nil)
     |> load()}
  end

  @impl true
  def handle_event(event, params, socket) when event in @write_events do
    socket =
      socket
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:can_post?, can?(socket, @post))

    if permitted?(event, params, socket) do
      handle_write(event, params, socket)
    else
      {:noreply,
       put_flash(socket, :error, "You do not have permission to change goods receipts.")}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :pending, nil)}

  # Each action needs its own capability, read again for every write event.
  defp permitted?("transition", %{"action" => action}, socket),
    do: action_allowed?(action, socket)

  defp permitted?("confirm", _params, %{assigns: %{pending: nil}}), do: true

  defp permitted?("confirm", _params, %{assigns: %{pending: {action, _attrs}}} = socket),
    do: action_allowed?(Atom.to_string(action), socket)

  defp permitted?(_event, _params, _socket), do: false

  defp action_allowed?("cancel", %{assigns: assigns}), do: assigns.can_manage?

  defp action_allowed?(action, %{assigns: assigns}) when action in ~w(post reverse),
    do: assigns.can_post?

  defp action_allowed?(_action, _socket), do: false

  defp handle_write("transition", %{"action" => action} = params, socket) do
    {:noreply,
     assign(socket, :pending, {String.to_existing_atom(action), Map.take(params, ["reason"])})}
  end

  defp handle_write("confirm", _params, %{assigns: %{pending: nil}} = socket),
    do: {:noreply, socket}

  defp handle_write("confirm", _params, %{assigns: %{pending: {action, attrs}}} = socket) do
    socket = assign(socket, :pending, nil)

    case run(action, attrs, socket) do
      {:ok, message, to} ->
        {:noreply, socket |> load() |> put_flash(:success, message) |> navigate(to)}

      {:error, reason} ->
        {:noreply, socket |> load() |> put_flash(:error, Refusals.text(reason))}
    end
  end

  defp navigate(socket, nil), do: socket
  defp navigate(socket, to), do: push_navigate(socket, to: to)

  # The facade authorizes each action for the scope's actor when it runs
  # and records who performed it; the page passes no actor.
  defp run(:post, _attrs, socket) do
    case Receiving.post_receipt(scope(socket), company_id(socket), receipt_id(socket)) do
      {:ok, _receipt} ->
        {:ok, "Receipt posted; the order's received quantities are updated.", nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run(:cancel, attrs, socket) do
    case Receiving.cancel_receipt(scope(socket), company_id(socket), receipt_id(socket), attrs) do
      {:ok, _receipt} -> {:ok, "Draft receipt cancelled.", nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(:reverse, attrs, socket) do
    case Receiving.reverse_receipt(scope(socket), company_id(socket), receipt_id(socket), attrs) do
      {:ok, reversal} ->
        {:ok, "Receipt reversed by goods receipt #{reversal.receipt_number}.",
         ~p"/supply-chain/receipts/#{reversal.id}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load(socket) do
    case Receiving.get_receipt(scope(socket), company_id(socket), receipt_id(socket)) do
      {:ok, receipt} ->
        socket
        |> assign(:receipt, receipt)
        |> assign(:page_title, "Goods receipt #{receipt.receipt_number}")

      {:error, _reason} ->
        socket |> assign(:receipt, nil) |> assign(:page_title, "Goods receipt")
    end
  end

  defp pending_text({:post, _attrs}, receipt),
    do:
      {"Goods receipt #{receipt.receipt_number} will be posted against PO #{receipt.order_number}.",
       "Its accepted quantities count as received on the order, and the receipt is fixed from then on; a mistake is corrected by a reversal. This cannot be undone.",
       "Post", "Posting…"}

  defp pending_text({:cancel, _attrs}, receipt),
    do:
      {"Draft goods receipt #{receipt.receipt_number} will be cancelled.",
       "It keeps its number and history and is never posted. This cannot be undone.",
       "Cancel receipt", "Cancelling…"}

  defp pending_text({:reverse, _attrs}, receipt),
    do:
      {"Goods receipt #{receipt.receipt_number} will be reversed.",
       "A reversal receipt takes its accepted quantities back off PO #{receipt.order_number}; the goods are received again with a new receipt. This cannot be undone.",
       "Reverse", "Reversing…"}

  defp reversible?(receipt),
    do:
      receipt.status == "posted" and receipt.kind == "receipt" and
        is_nil(receipt.reversed_by_receipt_id)

  defp can?(socket, capability), do: Authz.can(scope(socket), capability).allowed
  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]
  defp receipt_id(socket), do: socket.assigns.receipt_id

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="receiving-receipt" variant={:detail}>
        <div :if={@receipt == nil} class="mt-5">
          <.empty_state
            id="receipt-missing"
            title="This goods receipt is not available."
            reason="It may belong to another company, or the link is out of date."
          >
            <:action>
              <.button navigate={~p"/supply-chain/receipts"}>Back to goods receipts</.button>
            </:action>
          </.empty_state>
        </div>

        <div :if={@receipt} class="space-y-5">
          <.header>
            Goods receipt {@receipt.receipt_number}
            <:subtitle>
              <.badge kind={Forms.status_kind(@receipt.status)}>
                {Forms.label(@receipt.status)}
              </.badge>
              <span class="ml-2">{Forms.label(@receipt.kind)} against PO {@receipt.order_number}</span>
            </:subtitle>
            <:actions>
              <.link navigate={~p"/supply-chain/receipts"} class="text-sm text-link hover:underline">
                ← Goods receipts
              </.link>
            </:actions>
          </.header>

          <.card id="receipt-details" inner_class="p-5 sm:p-6">
            <.section_heading id="receipt-details-heading" title="Details" />
            <dl id="receipt-facts" class="mt-3 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
              <div>
                <dt class="text-xs text-ink-muted">Purchase order</dt>
                <dd>
                  <.link
                    id="receipt-order-link"
                    navigate={~p"/supply-chain/purchase-orders/#{@receipt.order_id}"}
                    class="text-link hover:underline"
                  >
                    PO {@receipt.order_number}
                  </.link>
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Received on</dt>
                <dd>{Forms.date(@receipt.received_on)}</dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Delivery note</dt>
                <dd>{@receipt.supplier_reference || "—"}</dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Recorded by</dt>
                <dd>
                  user {@receipt.created_by_user_id}<span :if={@receipt.created_by_impersonator_id}> (as user {@receipt.created_by_impersonator_id})</span>
                </dd>
              </div>
              <div :if={@receipt.posted_at}>
                <dt class="text-xs text-ink-muted">Posted</dt>
                <dd>
                  by user {@receipt.posted_by_user_id}<span :if={@receipt.posted_by_impersonator_id}> (as user {@receipt.posted_by_impersonator_id})</span>
                  <.datetime id="receipt-posted-at" value={@receipt.posted_at} precision={:second} />
                </dd>
              </div>
              <div :if={@receipt.reverses_receipt_id}>
                <dt class="text-xs text-ink-muted">Reverses</dt>
                <dd>
                  <.link
                    id="receipt-reverses-link"
                    navigate={~p"/supply-chain/receipts/#{@receipt.reverses_receipt_id}"}
                    class="text-link hover:underline"
                  >
                    GR {@receipt.reverses_receipt_number}
                  </.link>
                  <span class="block">{@receipt.reason}</span>
                </dd>
              </div>
              <div :if={@receipt.reversed_by_receipt_id}>
                <dt class="text-xs text-ink-muted">Reversed by</dt>
                <dd>
                  <.link
                    id="receipt-reversed-by-link"
                    navigate={~p"/supply-chain/receipts/#{@receipt.reversed_by_receipt_id}"}
                    class="text-link hover:underline"
                  >
                    GR {@receipt.reversed_by_receipt_number}
                  </.link>
                </dd>
              </div>
              <div class="sm:col-span-2">
                <dt class="text-xs text-ink-muted">Notes</dt>
                <dd>{@receipt.notes || "—"}</dd>
              </div>
            </dl>
          </.card>

          <.card id="receipt-lines" inner_class="p-0">
            <.table
              id="receipt-lines-table"
              rows={@receipt.lines}
              caption="Receipt lines"
              framed={false}
            >
              <:col :let={line} label="#">{line.line_number}</:col>
              <:col :let={line} label="Order line">{line.order_line_number}</:col>
              <:col :let={line} label="Description">{line.description}</:col>
              <:col :let={line} label="Ordered" align={:right}>
                {Forms.quantity(line.ordered_quantity)} {line.unit}
              </:col>
              <:col :let={line} label="Accepted" align={:right}>
                {Forms.quantity(line.received_quantity)}
              </:col>
              <:col :let={line} label="Rejected" align={:right}>
                {Forms.quantity(line.rejected_quantity)}
              </:col>
              <:col :let={line} label="Rejection reason">{line.rejection_reason || "—"}</:col>
            </.table>
          </.card>

          <.card id="receipt-actions" inner_class="p-5 sm:p-6">
            <.section_heading id="receipt-actions-heading" title="Actions" />
            <div class="mt-3 flex flex-wrap gap-2">
              <.button
                :if={@can_post? and @receipt.status == "draft"}
                id="receipt-post"
                type="button"
                variant="primary"
                phx-click="transition"
                phx-value-action="post"
              >Post receipt</.button>
              <form
                :if={@can_manage? and @receipt.status == "draft"}
                id="receipt-cancel"
                phx-submit="transition"
                class="flex flex-wrap gap-1"
              >
                <input type="hidden" name="action" value="cancel" />
                <input
                  name="reason"
                  aria-label="Cancellation reason"
                  placeholder="Reason"
                  maxlength="500"
                  class={["w-48", @input]}
                />
                <.button type="submit" variant="danger">Cancel receipt</.button>
              </form>
              <form
                :if={@can_post? and reversible?(@receipt)}
                id="receipt-reverse"
                phx-submit="transition"
                class="flex flex-wrap gap-1"
              >
                <input type="hidden" name="action" value="reverse" />
                <input
                  name="reason"
                  aria-label="Reversal reason"
                  placeholder="Reason"
                  maxlength="500"
                  class={["w-48", @input]}
                />
                <.button type="submit" variant="danger">Reverse receipt</.button>
              </form>
              <p
                :if={
                  @receipt.status == "cancelled" or
                    (@receipt.status == "posted" and not reversible?(@receipt))
                }
                id="receipt-final"
                class="text-sm text-ink-muted"
              >
                This receipt is {if @receipt.reversed_by_receipt_id,
                  do: "reversed",
                  else: Forms.label(@receipt.status) |> String.downcase()}; it keeps its lines and history and takes no further action.
              </p>
              <p
                :if={
                  not @can_manage? and not @can_post? and
                    (@receipt.status == "draft" or reversible?(@receipt))
                }
                id="receipt-actions-forbidden"
                class="text-sm text-ink-muted"
              >
                You do not have permission to change goods receipts.
              </p>
            </div>
          </.card>

          <.card id="receipt-history" inner_class="p-5 sm:p-6">
            <.section_heading
              id="receipt-history-heading"
              title="History"
              count={length(@receipt.events)}
            />
            <ul id="receipt-events" class="mt-3 divide-y divide-line text-sm">
              <li
                :for={event <- @receipt.events}
                id={"receipt-event-#{event.id}"}
                class="flex flex-wrap items-center gap-3 py-2"
              >
                <.badge kind={Forms.status_kind(event.to_status)}>
                  {Forms.label(event.to_status)}
                </.badge>
                <span :if={event.from_status} class="text-ink-muted">from {Forms.label(
                  event.from_status
                )}</span>
                <span class="text-ink-muted">by user {event.actor_user_id}<span :if={
                  event.actor_impersonator_id
                }> (as user {event.actor_impersonator_id})</span></span>
                <.datetime
                  id={"receipt-event-at-#{event.id}"}
                  value={event.occurred_at}
                  precision={:second}
                />
                <span :if={event.reason}>{event.reason}</span>
              </li>
            </ul>
          </.card>
        </div>

        <.confirm_dialog
          :if={@pending && @receipt}
          id="receipt-confirm"
          consequence={elem(pending_text(@pending, @receipt), 0)}
          detail={elem(pending_text(@pending, @receipt), 1)}
          confirm={elem(pending_text(@pending, @receipt), 2)}
          working={elem(pending_text(@pending, @receipt), 3)}
          on_confirm={JS.push("confirm")}
          on_cancel={JS.push("dismiss")}
        />
      </.page>
    </Layouts.app>
    """
  end
end
