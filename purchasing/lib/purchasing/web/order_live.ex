defmodule Bilimbi.SupplyChain.Purchasing.Web.OrderLive do
  @moduledoc """
  One purchase order through the Purchasing facade: its header, current
  lines and totals, status history, and amendments, with the transitions
  its status allows. Viewing needs `supply-chain.purchasing.view`; submit,
  send, close, and cancel need `supply-chain.purchasing.orders.manage`,
  approve and return need `supply-chain.purchasing.orders.approve`, and the
  facade checks the capability again when each runs. Every transition waits
  for confirmation, because none can be undone from this page.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.Web.Forms
  alias Bilimbi.SupplyChain.Purchasing.Web.Refusals

  @manage "supply-chain.purchasing.orders.manage"
  @approve "supply-chain.purchasing.orders.approve"
  @write_events ~w(transition confirm)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "supply_chain.purchase_orders")
     |> assign(:order_id, Forms.integer(id))
     |> assign(:can_manage?, can?(socket, @manage))
     |> assign(:can_approve?, can?(socket, @approve))
     |> assign(:pending, nil)
     |> load()}
  end

  @impl true
  def handle_event(event, params, socket) when event in @write_events do
    socket =
      socket
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:can_approve?, can?(socket, @approve))

    if permitted?(event, params, socket) do
      handle_write(event, params, socket)
    else
      {:noreply,
       put_flash(socket, :error, "You do not have permission to change purchase orders.")}
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

  defp action_allowed?(action, %{assigns: assigns}) when action in ~w(submit send close cancel),
    do: assigns.can_manage?

  defp action_allowed?(action, %{assigns: assigns}) when action in ~w(approve return),
    do: assigns.can_approve?

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
      {:ok, message} -> {:noreply, socket |> load() |> put_flash(:success, message)}
      {:error, reason} -> {:noreply, socket |> load() |> put_flash(:error, Refusals.text(reason))}
    end
  end

  # The facade authorizes each transition for the scope's actor when it runs
  # and records who performed it; the page passes no actor.
  defp run(:submit, _attrs, socket),
    do:
      Purchasing.submit_order(scope(socket), company_id(socket), order_id(socket))
      |> result("Order submitted for approval.")

  defp run(:approve, attrs, socket),
    do:
      Purchasing.approve_order(scope(socket), company_id(socket), order_id(socket), attrs)
      |> result("Order approved.")

  defp run(:return, attrs, socket),
    do:
      Purchasing.return_order(scope(socket), company_id(socket), order_id(socket), attrs)
      |> result("Order returned to draft.")

  defp run(:send, _attrs, socket),
    do:
      Purchasing.send_order(scope(socket), company_id(socket), order_id(socket))
      |> result("Order marked as sent.")

  defp run(:close, attrs, socket),
    do:
      Purchasing.close_order(scope(socket), company_id(socket), order_id(socket), attrs)
      |> result("Order closed.")

  defp run(:cancel, attrs, socket),
    do:
      Purchasing.cancel_order(scope(socket), company_id(socket), order_id(socket), attrs)
      |> result("Order cancelled.")

  defp result({:ok, _value}, message), do: {:ok, message}
  defp result({:error, reason}, _message), do: {:error, reason}

  defp load(socket) do
    case Purchasing.get_order(scope(socket), company_id(socket), order_id(socket)) do
      {:ok, order} ->
        socket
        |> assign(:order, order)
        |> assign(:page_title, "Purchase order #{order.order_number}")

      {:error, _reason} ->
        socket |> assign(:order, nil) |> assign(:page_title, "Purchase order")
    end
  end

  defp pending_text({:submit, _attrs}, order),
    do:
      {"Purchase order #{order.order_number} will be submitted for approval.",
       "Its supplier, currency and lines are fixed from then on unless an approver returns it.",
       "Submit", "Submitting…"}

  defp pending_text({:approve, _attrs}, order),
    do:
      {"Purchase order #{order.order_number} will be approved.",
       "From then on it changes only through a recorded amendment. This cannot be undone.",
       "Approve", "Approving…"}

  defp pending_text({:return, _attrs}, order),
    do:
      {"Purchase order #{order.order_number} will go back to draft.",
       "The submitter sees your reason and may resubmit it.", "Return", "Returning…"}

  defp pending_text({:send, _attrs}, order),
    do:
      {"Purchase order #{order.order_number} will be marked as sent to #{supplier_name(order)}.",
       "Receipts can be recorded against it from then on. This cannot be undone.", "Mark sent",
       "Marking…"}

  defp pending_text({:close, _attrs}, order),
    do:
      {"Purchase order #{order.order_number} will be closed.",
       "No further receipt can be recorded against it. This cannot be undone.", "Close",
       "Closing…"}

  defp pending_text({:cancel, _attrs}, order),
    do:
      {"Purchase order #{order.order_number} will be cancelled.",
       "It keeps its number, lines and history. This cannot be undone.", "Cancel order",
       "Cancelling…"}

  defp supplier_name(%{supplier: %{name: name}}), do: name
  defp supplier_name(_order), do: "the supplier"

  defp can?(socket, capability), do: Authz.can(scope(socket), capability).allowed
  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]
  defp order_id(socket), do: socket.assigns.order_id

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="purchasing-order" variant={:detail}>
        <div :if={@order == nil} class="mt-5">
          <.empty_state
            id="order-missing"
            title="This purchase order is not available."
            reason="It may belong to another company, or the link is out of date."
          >
            <:action>
              <.button navigate={~p"/supply-chain/purchase-orders"}>Back to purchase orders</.button>
            </:action>
          </.empty_state>
        </div>

        <div :if={@order} class="space-y-5">
          <.header>
            Purchase order {@order.order_number}
            <:subtitle>
              <.badge kind={Forms.status_kind(@order.status)}>
                {Forms.status_label(@order.status)}
              </.badge>
              <span class="ml-2">{supplier_name(@order)} · {@order.currency_code}</span>
            </:subtitle>
            <:actions>
              <.link
                navigate={~p"/supply-chain/purchase-orders"}
                class="text-sm text-link hover:underline"
              >← Purchase orders</.link>
            </:actions>
          </.header>

          <.card id="order-details" inner_class="p-5 sm:p-6">
            <.section_heading id="order-details-heading" title="Details" />
            <dl id="order-facts" class="mt-3 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
              <div>
                <dt class="text-xs text-ink-muted">Supplier</dt><dd>{supplier_name(@order)}</dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Supplier reference</dt><dd>
                  {@order.reference || "—"}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Expected delivery</dt><dd>
                  {Forms.date(@order.expected_on)}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">From request</dt><dd>
                  {@order.purchase_request_number || "—"}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Subtotal</dt><dd class="tabular-nums">
                  {Forms.money(@order.subtotal)} {@order.currency_code}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Tax</dt><dd class="tabular-nums">
                  {Forms.money(@order.tax_total)} {@order.currency_code}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Total</dt><dd class="tabular-nums font-medium">
                  {Forms.money(@order.total)} {@order.currency_code}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-ink-muted">Amendments</dt><dd>{@order.amendment_count}</dd>
              </div>
              <div class="sm:col-span-2">
                <dt class="text-xs text-ink-muted">Notes</dt><dd>{@order.notes || "—"}</dd>
              </div>
            </dl>
          </.card>

          <.card id="order-lines" inner_class="p-0">
            <.table id="order-lines-table" rows={@order.lines} caption="Order lines" framed={false}>
              <:col :let={line} label="#">{line.line_number}</:col>
              <:col :let={line} label="Description">
                {line.description}
                <span :if={line.external_item_ref} class="block text-xs text-ink-muted">{line.external_item_ref}</span>
              </:col>
              <:col :let={line} label="Quantity" align={:right}>
                {Forms.money(line.quantity)} {line.unit}
              </:col>
              <:col :let={line} label="Unit price" align={:right}>
                {Forms.money(line.unit_price)}
              </:col>
              <:col :let={line} label="Tax %" align={:right}>{Forms.money(line.tax_rate)}</:col>
              <:col :let={line} label="Line total" align={:right}>
                {Forms.money(line.line_total)}
              </:col>
              <:col :let={line} label="Received" align={:right}>
                {Forms.money(line.received_quantity)}
              </:col>
              <:empty
                :if={@order.lines == []}
                title="No lines"
                reason="A draft needs at least one line before it is submitted."
              />
            </.table>
          </.card>

          <.card id="order-actions" inner_class="p-5 sm:p-6">
            <.section_heading id="order-actions-heading" title="Actions" />
            <div class="mt-3 flex flex-wrap gap-2">
              <.button
                :if={@can_manage? and @order.status == "draft"}
                id="order-submit"
                type="button"
                phx-click="transition"
                phx-value-action="submit"
              >Submit for approval</.button>
              <form
                :if={@can_approve? and @order.status == "submitted"}
                id="order-decide"
                phx-submit="transition"
                class="flex flex-wrap gap-1"
              >
                <input
                  name="reason"
                  aria-label="Reason"
                  placeholder="Reason"
                  maxlength="500"
                  class={["w-48", @input]}
                />
                <.button type="submit" name="action" value="approve" variant="primary">Approve</.button>
                <.button
                  :if={@order.amendment_count == 0}
                  type="submit"
                  name="action"
                  value="return"
                >Return to draft</.button>
              </form>
              <.button
                :if={@can_manage? and @order.status == "approved"}
                id="order-send"
                type="button"
                phx-click="transition"
                phx-value-action="send"
              >Mark as sent</.button>
              <form
                :if={@can_manage? and @order.status in ["sent", "partially_received"]}
                id="order-close"
                phx-submit="transition"
                class="flex flex-wrap gap-1"
              >
                <input type="hidden" name="action" value="close" />
                <input
                  name="reason"
                  aria-label="Closing reason"
                  placeholder="Reason"
                  maxlength="500"
                  class={["w-48", @input]}
                />
                <.button type="submit">Close</.button>
              </form>
              <form
                :if={@can_manage? and @order.status not in ["closed", "cancelled"]}
                id="order-cancel"
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
                <.button type="submit" variant="danger">Cancel order</.button>
              </form>
              <p
                :if={@order.status in ["closed", "cancelled"]}
                id="order-final"
                class="text-sm text-ink-muted"
              >
                This order is {Forms.status_label(@order.status) |> String.downcase()}; it keeps its history and takes no further action.
              </p>
              <p
                :if={
                  not @can_manage? and not @can_approve? and
                    @order.status not in ["closed", "cancelled"]
                }
                id="order-actions-forbidden"
                class="text-sm text-ink-muted"
              >
                You do not have permission to change purchase orders.
              </p>
            </div>
          </.card>

          <.card id="order-history" inner_class="p-5 sm:p-6">
            <.section_heading
              id="order-history-heading"
              title="History"
              count={length(@order.events)}
            />
            <ul id="order-events" class="mt-3 divide-y divide-line text-sm">
              <li
                :for={event <- @order.events}
                id={"order-event-#{event.id}"}
                class="flex flex-wrap items-center gap-3 py-2"
              >
                <.badge kind={Forms.status_kind(event.to_status)}>
                  {Forms.status_label(event.to_status)}
                </.badge>
                <span :if={event.from_status} class="text-ink-muted">from {Forms.status_label(
                  event.from_status
                )}</span>
                <span class="text-ink-muted">by user {event.actor_user_id}<span :if={
                  event.actor_impersonator_id
                }> (as user {event.actor_impersonator_id})</span></span>
                <.datetime
                  id={"order-event-at-#{event.id}"}
                  value={event.occurred_at}
                  precision={:second}
                />
                <span :if={event.reason}>{event.reason}</span>
              </li>
            </ul>
          </.card>

          <.card :if={@order.amendments != []} id="order-amendments" inner_class="p-5 sm:p-6">
            <.section_heading
              id="order-amendments-heading"
              title="Amendments"
              count={length(@order.amendments)}
            />
            <ul id="order-amendment-list" class="mt-3 divide-y divide-line text-sm">
              <li
                :for={amendment <- @order.amendments}
                id={"order-amendment-#{amendment.id}"}
                class="py-2"
              >
                <span class="font-medium">Amendment {amendment.amendment_number}</span>
                <span class="text-ink-muted">by user {amendment.amended_by_user_id}</span>
                <.datetime
                  id={"order-amendment-at-#{amendment.id}"}
                  value={amendment.occurred_at}
                  precision={:second}
                />
                <span class="block">{amendment.reason}</span>
                <span class="block text-xs text-ink-muted">
                  Added {length(amendment.lines)} line(s); replaced {length(
                    amendment.superseded_line_ids
                  )}.
                </span>
              </li>
            </ul>
          </.card>
        </div>

        <.confirm_dialog
          :if={@pending && @order}
          id="order-confirm"
          consequence={elem(pending_text(@pending, @order), 0)}
          detail={elem(pending_text(@pending, @order), 1)}
          confirm={elem(pending_text(@pending, @order), 2)}
          working={elem(pending_text(@pending, @order), 3)}
          on_confirm={JS.push("confirm")}
          on_cancel={JS.push("dismiss")}
        />
      </.page>
    </Layouts.app>
    """
  end
end
