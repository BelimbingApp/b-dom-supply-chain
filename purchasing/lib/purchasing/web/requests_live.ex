defmodule Bilimbi.SupplyChain.Purchasing.Web.RequestsLive do
  @moduledoc """
  The signed-in company's purchase requests through the Purchasing facade:
  create a draft with its lines, submit it, decide it, cancel it, or turn
  an approved one into a draft purchase order. Viewing needs
  `supply-chain.purchasing.view`; each write needs its own capability, which
  the facade checks again when it runs. Decisions and cancellations wait
  for confirmation because nobody can undo them from this page.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.Web.Forms
  alias Bilimbi.SupplyChain.Purchasing.Web.Refusals

  @manage "supply-chain.purchasing.requests.manage"
  @approve "supply-chain.purchasing.requests.approve"
  @manage_orders "supply-chain.purchasing.orders.manage"
  @tabs ["all" | Purchasing.request_statuses()]
  @write_events ~w(save submit decide cancel create_order confirm)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Purchase requests")
     |> assign(:active_nav, "supply_chain.purchase_requests")
     |> assign(:tabs, @tabs)
     |> assign(:can_manage?, can?(socket, @manage))
     |> assign(:can_approve?, can?(socket, @approve))
     |> assign(:can_order?, can?(socket, @manage_orders))
     |> assign(:form, request_form(%{}))
     |> assign(:rows, Forms.blank_lines())
     |> assign(:pending, nil)
     |> assign(:suppliers, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["status"] in @tabs, do: params["status"], else: "all"
    {:noreply, socket |> assign(:tab, tab) |> assign(:pending, nil) |> load()}
  end

  @impl true
  def handle_event(
        event,
        _params,
        %{assigns: %{can_manage?: false, can_approve?: false}} = socket
      )
      when event in @write_events do
    {:noreply,
     put_flash(socket, :error, "You do not have permission to work on purchase requests.")}
  end

  def handle_event("save", %{"request" => params}, socket) do
    attributes = Map.put(params, "lines", Forms.lines_from_params(params["lines"]))

    case Purchasing.create_request(scope(socket), company_id(socket), attributes) do
      {:ok, request} ->
        {:noreply,
         socket
         |> assign(:form, request_form(%{}))
         |> assign(:rows, Forms.blank_lines())
         |> load()
         |> put_flash(:success, "Purchase request #{request.request_number} saved as a draft.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, request_form(params))
         |> assign(:rows, Forms.rows_from_params(params["lines"]))
         |> put_flash(:error, Refusals.text(reason))}
    end
  end

  def handle_event("submit", %{"request_id" => id}, socket) do
    {:noreply, hold(socket, {:submit, Forms.integer(id), %{}})}
  end

  def handle_event("decide", %{"request_id" => id, "decision" => decision} = params, socket)
      when decision in ["approve", "reject"] do
    action = if decision == "approve", do: :approve, else: :reject
    {:noreply, hold(socket, {action, Forms.integer(id), Map.take(params, ["reason"])})}
  end

  def handle_event("cancel", %{"request_id" => id} = params, socket) do
    {:noreply, hold(socket, {:cancel, Forms.integer(id), Map.take(params, ["reason"])})}
  end

  def handle_event("create_order", %{"request_id" => id} = params, socket) do
    attributes = Map.take(params, ["supplier_id", "currency_code"])

    case Purchasing.create_order_from_request(
           scope(socket),
           company_id(socket),
           Forms.integer(id),
           attributes
         ) do
      {:ok, order} ->
        {:noreply,
         socket
         |> put_flash(:success, "Purchase order #{order.order_number} drafted from the request.")
         |> push_navigate(to: ~p"/supply-chain/purchase-orders/#{order.id}")}

      {:error, reason} ->
        {:noreply, socket |> load() |> put_flash(:error, Refusals.text(reason))}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :pending, nil)}

  def handle_event("confirm", _params, %{assigns: %{pending: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm", _params, %{assigns: %{pending: pending}} = socket) do
    socket = assign(socket, :pending, nil)

    case run(pending, socket) do
      {:ok, message} ->
        {:noreply, socket |> load() |> put_flash(:success, message)}

      {:error, reason} ->
        {:noreply, socket |> load() |> put_flash(:error, Refusals.text(reason))}
    end
  end

  # A held action is confirmed before it runs; the facade authorizes it for
  # the scope's actor when it runs and records who performed it.
  defp hold(socket, {_action, nil, _attrs}),
    do: put_flash(socket, :error, Refusals.text(:request_not_found))

  defp hold(socket, pending), do: assign(socket, :pending, pending)

  defp run({:submit, id, _attrs}, socket),
    do:
      Purchasing.submit_request(scope(socket), company_id(socket), id)
      |> result("Request submitted for approval.")

  defp run({:approve, id, attrs}, socket),
    do:
      Purchasing.approve_request(scope(socket), company_id(socket), id, attrs)
      |> result("Request approved.")

  defp run({:reject, id, attrs}, socket),
    do:
      Purchasing.reject_request(scope(socket), company_id(socket), id, attrs)
      |> result("Request rejected.")

  defp run({:cancel, id, attrs}, socket),
    do:
      Purchasing.cancel_request(scope(socket), company_id(socket), id, attrs)
      |> result("Request cancelled.")

  defp result({:ok, _value}, message), do: {:ok, message}
  defp result({:error, reason}, _message), do: {:error, reason}

  defp load(socket) do
    options = if socket.assigns.tab == "all", do: [], else: [status: socket.assigns.tab]

    socket =
      case Purchasing.list_requests(scope(socket), company_id(socket), options) do
        {:ok, requests} -> assign(socket, :requests, requests)
        {:error, _reason} -> assign(socket, :requests, [])
      end

    if socket.assigns.can_order? do
      case Purchasing.list_suppliers(scope(socket), company_id(socket), active: true) do
        {:ok, suppliers} -> assign(socket, :suppliers, suppliers)
        {:error, _reason} -> assign(socket, :suppliers, [])
      end
    else
      socket
    end
  end

  defp request_form(params) do
    to_form(
      Map.merge(
        %{"title" => "", "justification" => "", "needed_on" => ""},
        Map.drop(params, ["lines"])
      ),
      as: :request
    )
  end

  defp pending_text({:submit, id, _attrs}),
    do:
      {"Purchase request #{id} will be submitted for approval.",
       "Its title and lines are fixed from then on; an approver decides it.", "Submit",
       "Submitting…"}

  defp pending_text({:approve, id, _attrs}),
    do:
      {"Purchase request #{id} will be approved.",
       "The decision is recorded with your name and cannot be undone.", "Approve", "Approving…"}

  defp pending_text({:reject, id, _attrs}),
    do:
      {"Purchase request #{id} will be rejected.",
       "The requester sees your reason. This cannot be undone.", "Reject", "Rejecting…"}

  defp pending_text({:cancel, id, _attrs}),
    do:
      {"Purchase request #{id} will be cancelled.",
       "It keeps its number and history. This cannot be undone.", "Cancel request", "Cancelling…"}

  defp can?(socket, capability), do: Authz.can(scope(socket), capability).allowed
  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  @input "rounded-md border border-line bg-surface px-3 py-1.5 text-sm"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :input, @input)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="purchasing-requests" variant={:list}>
        <.header>
          Purchase requests
          <:subtitle>What the company needs to buy, before a purchase order is raised.</:subtitle>
        </.header>

        <.card :if={@can_manage?} id="request-editor" title="New purchase request" class="mt-5">
          <.form for={@form} id="request-form" phx-submit="save" class="p-4">
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input field={@form[:title]} label="Title" />
              <.input field={@form[:needed_on]} type="date" label="Needed by" />
            </div>
            <.input field={@form[:justification]} type="textarea" label="Justification" />
            <table id="request-form-lines" class="w-full text-left text-sm">
              <thead class="text-xs text-ink-muted">
                <tr>
                  <th class="px-1 py-1">Description</th>
                  <th class="px-1 py-1">Quantity</th>
                  <th class="px-1 py-1">Unit</th>
                  <th class="px-1 py-1">Item reference</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{index, row} <- @rows}>
                  <td class="px-1 py-0.5">
                    <input
                      name={"request[lines][#{index}][description]"}
                      value={row["description"]}
                      aria-label={"Line #{index + 1} description"}
                      class={["w-full", @input]}
                    />
                  </td>
                  <td class="px-1 py-0.5">
                    <input
                      name={"request[lines][#{index}][quantity]"}
                      value={row["quantity"]}
                      inputmode="decimal"
                      aria-label={"Line #{index + 1} quantity"}
                      class={["w-24", @input]}
                    />
                  </td>
                  <td class="px-1 py-0.5">
                    <input
                      name={"request[lines][#{index}][unit]"}
                      value={row["unit"]}
                      aria-label={"Line #{index + 1} unit"}
                      class={["w-24", @input]}
                    />
                  </td>
                  <td class="px-1 py-0.5">
                    <input
                      name={"request[lines][#{index}][external_item_ref]"}
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

        <.tabs id="request-tabs" aria-label="Request statuses" class="mt-5">
          <:tab
            :for={tab <- @tabs}
            id={"request-tab-#{tab}"}
            patch={~p"/supply-chain/purchase-requests?status=#{tab}"}
            current={@tab == tab}
          >
            {if tab == "all", do: "All", else: Forms.status_label(tab)}
          </:tab>
        </.tabs>

        <.card id="requests" inner_class="p-0" class="mt-3">
          <.table id="requests-table" rows={@requests} caption="Purchase requests" framed={false}>
            <:col :let={request} label="Number">{request.request_number}</:col>
            <:col :let={request} label="Title">
              {request.title}
              <span :if={request.decision_reason} class="block text-xs text-ink-muted">{request.decision_reason}</span>
            </:col>
            <:col :let={request} label="Lines">{length(request.lines)}</:col>
            <:col :let={request} label="Needed by">{Forms.date(request.needed_on)}</:col>
            <:col :let={request} label="Status">
              <.badge kind={Forms.status_kind(request.status)}>
                {Forms.status_label(request.status)}
              </.badge>
            </:col>
            <:action :let={request}>
              <div id={"request-actions-#{request.id}"} class="flex flex-wrap gap-2">
                <.button
                  :if={@can_manage? and request.status == "draft"}
                  type="button"
                  phx-click="submit"
                  phx-value-request_id={request.id}
                >
                  Submit
                </.button>
                <form
                  :if={@can_approve? and request.status == "submitted"}
                  id={"decide-#{request.id}"}
                  phx-submit="decide"
                  class="flex flex-wrap gap-1"
                >
                  <input type="hidden" name="request_id" value={request.id} />
                  <input
                    name="reason"
                    aria-label="Reason"
                    placeholder="Reason"
                    maxlength="500"
                    class={["w-40", @input]}
                  />
                  <.button type="submit" name="decision" value="approve">Approve</.button>
                  <.button type="submit" name="decision" value="reject">Reject</.button>
                </form>
                <form
                  :if={@can_order? and request.status == "approved"}
                  id={"order-from-#{request.id}"}
                  phx-submit="create_order"
                  class="flex flex-wrap gap-1"
                >
                  <input type="hidden" name="request_id" value={request.id} />
                  <select name="supplier_id" aria-label="Supplier" class={@input}>
                    <option value="">Supplier…</option>
                    <option :for={supplier <- @suppliers} value={supplier.id}>{supplier.name}</option>
                  </select>
                  <input
                    name="currency_code"
                    aria-label="Currency"
                    placeholder="Currency"
                    maxlength="3"
                    class={["w-24", @input]}
                  />
                  <.button type="submit">Create order</.button>
                </form>
                <form
                  :if={@can_manage? and request.status in ["draft", "submitted", "approved"]}
                  id={"cancel-#{request.id}"}
                  phx-submit="cancel"
                  class="flex flex-wrap gap-1"
                >
                  <input type="hidden" name="request_id" value={request.id} />
                  <input
                    name="reason"
                    aria-label="Cancellation reason"
                    placeholder="Reason"
                    maxlength="500"
                    class={["w-40", @input]}
                  />
                  <.button type="submit">Cancel</.button>
                </form>
              </div>
            </:action>
            <:empty
              :if={@requests == []}
              title="No purchase requests here"
              reason={
                if @tab == "all",
                  do: "Requests you create appear here.",
                  else: "No request is #{Forms.status_label(@tab) |> String.downcase()}."
              }
            />
          </.table>
        </.card>

        <.confirm_dialog
          :if={@pending}
          id="request-confirm"
          consequence={elem(pending_text(@pending), 0)}
          detail={elem(pending_text(@pending), 1)}
          confirm={elem(pending_text(@pending), 2)}
          working={elem(pending_text(@pending), 3)}
          on_confirm={JS.push("confirm")}
          on_cancel={JS.push("dismiss")}
        />
      </.page>
    </Layouts.app>
    """
  end
end
