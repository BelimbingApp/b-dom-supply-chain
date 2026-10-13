defmodule Bilimbi.SupplyChain.Receiving.Web.ReceiveLive do
  @moduledoc """
  Receives goods against one purchase order through the Receiving facade:
  the person picks a sent or partially received order, enters what was
  accepted and what was rejected per line, and saves a draft receipt to
  post from its page. Viewing needs `supply-chain.receiving.view`; saving
  needs `supply-chain.receiving.receipts.manage`, which the facade checks
  again when the draft is saved. Orders come through Purchasing's facade
  under the same actor, so the page needs `supply-chain.purchasing.view` to
  list them.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Receiving
  alias Bilimbi.SupplyChain.Receiving.Web.Forms
  alias Bilimbi.SupplyChain.Receiving.Web.Refusals

  @manage "supply-chain.receiving.receipts.manage"
  @write_events ~w(save)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Receive goods")
     |> assign(:active_nav, "supply_chain.receipts")
     |> assign(:can_manage?, can?(socket, @manage))
     |> assign(:orders, receivable_orders(socket))
     |> assign(:form, receipt_form(%{}))
     |> assign(:rows, %{})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    order_id = Forms.integer(params["order"])

    order =
      with id when is_integer(id) <- order_id,
           {:ok, %{status: status} = order} when status in ~w(sent partially_received) <-
             Purchasing.get_order(scope(socket), company_id(socket), id) do
        order
      else
        _other -> nil
      end

    {:noreply,
     socket
     |> assign(:order_id, order_id)
     |> assign(:order, order)
     |> assign(
       :picker,
       to_form(%{"order_id" => order_id && Integer.to_string(order_id)}, as: :picker)
     )}
  end

  # Choosing an order is a read: the page patches to it.
  @impl true
  def handle_event("choose", %{"picker" => %{"order_id" => id}}, socket) do
    case Forms.integer(id) do
      nil -> {:noreply, push_patch(socket, to: ~p"/supply-chain/receive")}
      order_id -> {:noreply, push_patch(socket, to: ~p"/supply-chain/receive?order=#{order_id}")}
    end
  end

  def handle_event(event, params, socket) when event in @write_events do
    socket = assign(socket, :can_manage?, can?(socket, @manage))

    if socket.assigns.can_manage? do
      handle_write(event, params, socket)
    else
      {:noreply,
       put_flash(socket, :error, "You do not have permission to record goods receipts.")}
    end
  end

  defp handle_write(
         "save",
         %{"receipt" => params},
         %{assigns: %{order: %{id: order_id}}} = socket
       ) do
    attributes =
      params
      |> Map.take(["received_on", "supplier_reference", "notes"])
      |> Map.put("order_id", order_id)
      |> Map.put("lines", Forms.lines_from_params(params["lines"]))

    case Receiving.create_receipt(scope(socket), company_id(socket), attributes) do
      {:ok, receipt} ->
        {:noreply,
         socket
         |> put_flash(:success, "Goods receipt #{receipt.receipt_number} saved as a draft.")
         |> push_navigate(to: ~p"/supply-chain/receipts/#{receipt.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, receipt_form(params))
         |> assign(:rows, Forms.rows_from_params(params["lines"]))
         |> put_flash(:error, Refusals.text(reason))}
    end
  end

  defp handle_write("save", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Choose a purchase order first.")}

  # Sent and partially received orders, newest first, as the facade lists
  # one status at a time.
  defp receivable_orders(socket) do
    Receiving.receivable_order_statuses()
    |> Enum.flat_map(fn status ->
      case Purchasing.list_orders(scope(socket), company_id(socket), status: status) do
        {:ok, orders} -> orders
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(& &1.order_number, :desc)
  end

  defp receipt_form(params) do
    to_form(
      Map.merge(
        %{
          "received_on" => Date.to_iso8601(Date.utc_today()),
          "supplier_reference" => "",
          "notes" => ""
        },
        Map.drop(params, ["lines"])
      ),
      as: :receipt
    )
  end

  defp outstanding(line), do: Decimal.sub(line.quantity, line.received_quantity)

  defp order_label(order) do
    supplier = if order.supplier, do: order.supplier.name, else: "supplier"
    "PO #{order.order_number} · #{supplier} · #{Forms.label(order.status)}"
  end

  defp can?(socket, capability), do: Authz.can(scope(socket), capability).allowed
  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="receiving-receive" variant={:detail}>
        <.header>
          Receive goods
          <:subtitle>
            Record what arrived against a sent purchase order; the draft is posted from its page.
          </:subtitle>
          <:actions>
            <.link navigate={~p"/supply-chain/receipts"} class="text-sm text-link hover:underline">
              ← Goods receipts
            </.link>
          </:actions>
        </.header>

        <div :if={not @can_manage?} class="mt-5">
          <.empty_state
            id="receive-forbidden"
            title="You do not have permission to record goods receipts."
            reason="Ask for the receipts capability, or view the receipts list instead."
          />
        </div>

        <div :if={@can_manage?} class="mt-5 space-y-5">
          <.card id="order-picker-card" title="Purchase order">
            <.form for={@picker} id="order-picker" phx-change="choose" phx-submit="choose" class="p-4">
              <.input
                field={@picker[:order_id]}
                type="select"
                label="Order"
                prompt="Choose a sent order"
                options={Enum.map(@orders, &{order_label(&1), &1.id})}
                hint={
                  if @orders == [],
                    do: "No sent or partially received order to receive against.",
                    else: nil
                }
              />
            </.form>
          </.card>

          <.card
            :if={@order}
            id="receipt-editor"
            title={"Goods received against PO #{@order.order_number}"}
          >
            <.form for={@form} id="receipt-form" phx-submit="save" class="p-4">
              <div class="grid gap-x-4 sm:grid-cols-3">
                <.input field={@form[:received_on]} type="date" label="Received on" />
                <.input
                  field={@form[:supplier_reference]}
                  label="Delivery note"
                  hint="The supplier's reference for this delivery."
                />
              </div>
              <.input field={@form[:notes]} type="textarea" label="Notes" />
              <table id="receipt-form-lines" class="w-full text-left text-sm">
                <thead class="text-xs text-ink-muted">
                  <tr>
                    <th class="px-1 py-1">#</th>
                    <th class="px-1 py-1">Description</th>
                    <th class="px-1 py-1 text-right">Ordered</th>
                    <th class="px-1 py-1 text-right">Received so far</th>
                    <th class="px-1 py-1 text-right">Outstanding</th>
                    <th class="px-1 py-1">Accepted</th>
                    <th class="px-1 py-1">Rejected</th>
                    <th class="px-1 py-1">Rejection reason</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={line <- @order.lines} id={"receipt-form-line-#{line.id}"}>
                    <td class="px-1 py-0.5">{line.line_number}</td>
                    <td class="px-1 py-0.5">
                      {line.description}
                      <span :if={line.external_item_ref} class="block text-xs text-ink-muted">
                        {line.external_item_ref}
                      </span>
                    </td>
                    <td class="px-1 py-0.5 text-right tabular-nums">
                      {Forms.quantity(line.quantity)} {line.unit}
                    </td>
                    <td class="px-1 py-0.5 text-right tabular-nums">
                      {Forms.quantity(line.received_quantity)}
                    </td>
                    <td class="px-1 py-0.5 text-right tabular-nums">
                      {Forms.quantity(outstanding(line))}
                    </td>
                    <td class="px-1 py-0.5">
                      <input
                        name={"receipt[lines][#{line.id}][received_quantity]"}
                        value={@rows[line.id]["received_quantity"]}
                        inputmode="decimal"
                        aria-label={"Line #{line.line_number} accepted quantity"}
                        class={["w-24", @input]}
                      />
                    </td>
                    <td class="px-1 py-0.5">
                      <input
                        name={"receipt[lines][#{line.id}][rejected_quantity]"}
                        value={@rows[line.id]["rejected_quantity"]}
                        inputmode="decimal"
                        aria-label={"Line #{line.line_number} rejected quantity"}
                        class={["w-24", @input]}
                      />
                    </td>
                    <td class="px-1 py-0.5">
                      <input
                        name={"receipt[lines][#{line.id}][rejection_reason]"}
                        value={@rows[line.id]["rejection_reason"]}
                        maxlength="500"
                        aria-label={"Line #{line.line_number} rejection reason"}
                        class={["w-full", @input]}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
              <p class="mb-3 mt-1 text-xs text-ink-muted">
                Lines with no accepted or rejected quantity are left out. Accepted goods count against the order; rejected goods need a reason.
              </p>
              <.button type="submit" variant="primary">Save draft receipt</.button>
            </.form>
          </.card>

          <div :if={@order_id && @order == nil} class="mt-5">
            <.empty_state
              id="order-unavailable"
              title="This purchase order cannot be received against."
              reason="It is not sent or partially received, belongs to another company, or the link is out of date."
            />
          </div>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
