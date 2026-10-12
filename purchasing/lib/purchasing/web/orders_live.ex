defmodule Bilimbi.SupplyChain.Purchasing.Web.OrdersLive do
  @moduledoc """
  The signed-in company's purchase orders through the Purchasing facade:
  the list by status, and a form that drafts a new order with its lines.
  Viewing needs `supply-chain.purchasing.view`; drafting needs
  `supply-chain.purchasing.orders.manage`, which the facade checks again
  when the draft is saved. Each order's page carries its transitions.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.Web.Forms
  alias Bilimbi.SupplyChain.Purchasing.Web.Refusals

  @manage "supply-chain.purchasing.orders.manage"
  @tabs ["all" | Purchasing.order_statuses()]
  @write_events ~w(save)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Purchase orders")
     |> assign(:active_nav, "supply_chain.purchase_orders")
     |> assign(:tabs, @tabs)
     |> assign(:can_manage?, Authz.can(scope(socket), @manage).allowed)
     |> assign(:form, order_form(%{}))
     |> assign(:rows, Forms.blank_lines())
     |> assign(:suppliers, [])
     |> assign(:tax_codes, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["status"] in @tabs, do: params["status"], else: "all"
    {:noreply, socket |> assign(:tab, tab) |> load()}
  end

  @impl true
  def handle_event(event, params, socket) when event in @write_events do
    socket = assign(socket, :can_manage?, Authz.can(scope(socket), @manage).allowed)

    if socket.assigns.can_manage? do
      handle_write(event, params, socket)
    else
      {:noreply,
       put_flash(socket, :error, "You do not have permission to draft purchase orders.")}
    end
  end

  defp handle_write("save", %{"order" => params}, socket) do
    attributes = Map.put(params, "lines", Forms.lines_from_params(params["lines"]))

    case Purchasing.create_order(scope(socket), company_id(socket), attributes) do
      {:ok, order} ->
        {:noreply,
         socket
         |> put_flash(:success, "Purchase order #{order.order_number} saved as a draft.")
         |> push_navigate(to: ~p"/supply-chain/purchase-orders/#{order.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, order_form(params))
         |> assign(:rows, Forms.rows_from_params(params["lines"]))
         |> put_flash(:error, Refusals.text(reason))}
    end
  end

  defp load(socket) do
    options = if socket.assigns.tab == "all", do: [], else: [status: socket.assigns.tab]

    socket =
      case Purchasing.list_orders(scope(socket), company_id(socket), options) do
        {:ok, orders} -> assign(socket, :orders, orders)
        {:error, _reason} -> assign(socket, :orders, [])
      end

    if socket.assigns.can_manage? do
      with {:ok, suppliers} <-
             Purchasing.list_suppliers(scope(socket), company_id(socket), active: true),
           {:ok, tax_codes} <-
             Purchasing.list_tax_codes(scope(socket), company_id(socket), active: true) do
        socket |> assign(:suppliers, suppliers) |> assign(:tax_codes, tax_codes)
      else
        {:error, _reason} -> socket
      end
    else
      socket
    end
  end

  defp order_form(params) do
    to_form(
      Map.merge(
        %{
          "supplier_id" => "",
          "currency_code" => "",
          "reference" => "",
          "expected_on" => "",
          "notes" => ""
        },
        Map.drop(params, ["lines"])
      ),
      as: :order
    )
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="purchasing-orders" variant={:list}>
        <.header>
          Purchase orders
          <:subtitle>Orders placed with suppliers, from draft through approval to receipt.</:subtitle>
        </.header>

        <.card :if={@can_manage?} id="order-editor" title="New purchase order" class="mt-5">
          <.form for={@form} id="order-form" phx-submit="save" class="p-4">
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input
                field={@form[:supplier_id]}
                type="select"
                label="Supplier"
                prompt="Choose a supplier"
                options={Enum.map(@suppliers, &{&1.name, &1.id})}
                hint={
                  if @suppliers == [],
                    do: "No active supplier yet; add one under Suppliers.",
                    else: nil
                }
              />
              <.input
                field={@form[:currency_code]}
                label="Currency"
                maxlength="3"
                hint="Three letters, fixed once the order leaves draft."
              />
              <.input field={@form[:reference]} label="Supplier reference" />
              <.input field={@form[:expected_on]} type="date" label="Expected delivery" />
            </div>
            <.input field={@form[:notes]} type="textarea" label="Notes" />
            <table id="order-form-lines" class="w-full text-left text-sm">
              <thead class="text-xs text-ink-muted">
                <tr>
                  <th class="px-1 py-1">Description</th>
                  <th class="px-1 py-1">Quantity</th>
                  <th class="px-1 py-1">Unit</th>
                  <th class="px-1 py-1">Unit price</th>
                  <th class="px-1 py-1">Tax code</th>
                  <th class="px-1 py-1">Item reference</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{index, row} <- @rows}>
                  <td class="px-1 py-0.5">
                    <input
                      name={"order[lines][#{index}][description]"}
                      value={row["description"]}
                      aria-label={"Line #{index + 1} description"}
                      class={["w-full", @input]}
                    />
                  </td>
                  <td class="px-1 py-0.5">
                    <input
                      name={"order[lines][#{index}][quantity]"}
                      value={row["quantity"]}
                      inputmode="decimal"
                      aria-label={"Line #{index + 1} quantity"}
                      class={["w-24", @input]}
                    />
                  </td>
                  <td class="px-1 py-0.5">
                    <input
                      name={"order[lines][#{index}][unit]"}
                      value={row["unit"]}
                      aria-label={"Line #{index + 1} unit"}
                      class={["w-24", @input]}
                    />
                  </td>
                  <td class="px-1 py-0.5">
                    <input
                      name={"order[lines][#{index}][unit_price]"}
                      value={row["unit_price"]}
                      inputmode="decimal"
                      aria-label={"Line #{index + 1} unit price"}
                      class={["w-28", @input]}
                    />
                  </td>
                  <td class="px-1 py-0.5">
                    <select
                      name={"order[lines][#{index}][tax_code_id]"}
                      aria-label={"Line #{index + 1} tax code"}
                      class={@input}
                    >
                      <option value="">None</option>
                      <option
                        :for={tax_code <- @tax_codes}
                        value={tax_code.id}
                        selected={to_string(tax_code.id) == row["tax_code_id"]}
                      >
                        {tax_code.code}
                      </option>
                    </select>
                  </td>
                  <td class="px-1 py-0.5">
                    <input
                      name={"order[lines][#{index}][external_item_ref]"}
                      value={row["external_item_ref"]}
                      aria-label={"Line #{index + 1} item reference"}
                      class={["w-full", @input]}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
            <p class="mb-3 mt-1 text-xs text-ink-muted">Rows without a description are ignored.</p>
            <.button type="submit" variant="primary">Save draft</.button>
          </.form>
        </.card>

        <.tabs id="order-tabs" aria-label="Order statuses" class="mt-5">
          <:tab
            :for={tab <- @tabs}
            id={"order-tab-#{tab}"}
            patch={~p"/supply-chain/purchase-orders?status=#{tab}"}
            current={@tab == tab}
          >
            {if tab == "all", do: "All", else: Forms.status_label(tab)}
          </:tab>
        </.tabs>

        <.card id="orders" inner_class="p-0" class="mt-3">
          <.table id="orders-table" rows={@orders} caption="Purchase orders" framed={false}>
            <:col :let={order} label="Number">
              <.link
                id={"order-link-#{order.id}"}
                navigate={~p"/supply-chain/purchase-orders/#{order.id}"}
                class="text-link hover:underline"
              >
                PO {order.order_number}
              </.link>
            </:col>
            <:col :let={order} label="Supplier">
              {if order.supplier, do: order.supplier.name, else: "—"}
            </:col>
            <:col :let={order} label="Lines">{length(order.lines)}</:col>
            <:col :let={order} label="Total" align={:right}>
              {Forms.money(order.total)} {order.currency_code}
            </:col>
            <:col :let={order} label="Expected">{Forms.date(order.expected_on)}</:col>
            <:col :let={order} label="Status">
              <.badge kind={Forms.status_kind(order.status)}>
                {Forms.status_label(order.status)}
              </.badge>
            </:col>
            <:empty
              :if={@orders == []}
              title="No purchase orders here"
              reason={
                if @tab == "all",
                  do: "Orders you draft appear here.",
                  else: "No order is #{Forms.status_label(@tab) |> String.downcase()}."
              }
            />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
