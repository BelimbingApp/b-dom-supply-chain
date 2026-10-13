defmodule Bilimbi.SupplyChain.Receiving.Web.ReceiptsLive do
  @moduledoc """
  The signed-in company's goods receipts through the Receiving facade: the
  list by status, the way to a new receipt, and the company's over-receipt
  tolerance. Viewing needs `supply-chain.receiving.view`; drafting a receipt
  needs `supply-chain.receiving.receipts.manage` and setting the tolerance
  `supply-chain.receiving.configuration.manage`, which the facade checks
  again when the write runs.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.SupplyChain.Receiving
  alias Bilimbi.SupplyChain.Receiving.Web.Forms
  alias Bilimbi.SupplyChain.Receiving.Web.Refusals

  @manage "supply-chain.receiving.receipts.manage"
  @configure "supply-chain.receiving.configuration.manage"
  @tabs ["all" | Receiving.receipt_statuses()]
  @write_events ~w(save_settings)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Goods receipts")
     |> assign(:active_nav, "supply_chain.receipts")
     |> assign(:tabs, @tabs)
     |> assign(:can_manage?, can?(socket, @manage))
     |> assign(:can_configure?, can?(socket, @configure))
     |> assign(:settings, nil)
     |> assign(:settings_form, settings_form(%{}))
     |> load_settings()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["status"] in @tabs, do: params["status"], else: "all"
    {:noreply, socket |> assign(:tab, tab) |> load()}
  end

  @impl true
  def handle_event(event, params, socket) when event in @write_events do
    socket = assign(socket, :can_configure?, can?(socket, @configure))

    if socket.assigns.can_configure? do
      handle_write(event, params, socket)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to configure receiving.")}
    end
  end

  defp handle_write("save_settings", %{"settings" => params}, socket) do
    case Receiving.configure(scope(socket), company_id(socket), params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:settings_form, settings_form(%{}))
         |> put_flash(
           :success,
           "Over-receipt tolerance set to #{Forms.quantity(settings.over_receipt_tolerance_percent)} %."
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:settings_form, settings_form(params))
         |> put_flash(:error, Refusals.text(reason))}
    end
  end

  defp load(socket) do
    options = if socket.assigns.tab == "all", do: [], else: [status: socket.assigns.tab]

    case Receiving.list_receipts(scope(socket), company_id(socket), options) do
      {:ok, receipts} -> assign(socket, :receipts, receipts)
      {:error, _reason} -> assign(socket, :receipts, [])
    end
  end

  defp load_settings(socket) do
    case Receiving.get_settings(scope(socket), company_id(socket)) do
      {:ok, settings} -> assign(socket, :settings, settings)
      {:error, _reason} -> socket
    end
  end

  defp settings_form(params) do
    to_form(Map.merge(%{"over_receipt_tolerance_percent" => ""}, params), as: :settings)
  end

  defp can?(socket, capability), do: Authz.can(scope(socket), capability).allowed
  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="receiving-receipts" variant={:list}>
        <.header>
          Goods receipts
          <:subtitle>
            Goods booked in against purchase orders, with what was accepted and what was rejected.
          </:subtitle>
          <:actions>
            <.button
              :if={@can_manage?}
              id="receive-goods"
              navigate={~p"/supply-chain/receive"}
              variant="primary"
            >
              Receive goods
            </.button>
          </:actions>
        </.header>

        <.card
          :if={@can_configure?}
          id="receiving-settings"
          title="Over-receipt tolerance"
          class="mt-5"
        >
          <.form for={@settings_form} id="settings-form" phx-submit="save_settings" class="p-4">
            <p id="settings-current" class="mb-3 text-sm text-ink-muted">
              A line may be received up to {Forms.quantity(
                @settings && @settings.over_receipt_tolerance_percent
              )} % over its ordered quantity.
              <span :if={@settings && @settings.set_by_user_id}>
                Set by user {@settings.set_by_user_id}.
              </span>
            </p>
            <div class="flex flex-wrap items-end gap-2">
              <.input
                field={@settings_form[:over_receipt_tolerance_percent]}
                label="Tolerance %"
                inputmode="decimal"
                hint="0 to 100, up to four decimal places. Each change is kept as history."
              />
              <.button type="submit" variant="primary">Save tolerance</.button>
            </div>
          </.form>
        </.card>

        <.tabs id="receipt-tabs" aria-label="Receipt statuses" class="mt-5">
          <:tab
            :for={tab <- @tabs}
            id={"receipt-tab-#{tab}"}
            patch={~p"/supply-chain/receipts?status=#{tab}"}
            current={@tab == tab}
          >
            {if tab == "all", do: "All", else: Forms.label(tab)}
          </:tab>
        </.tabs>

        <.card id="receipts" inner_class="p-0" class="mt-3">
          <.table id="receipts-table" rows={@receipts} caption="Goods receipts" framed={false}>
            <:col :let={receipt} label="Number">
              <.link
                id={"receipt-link-#{receipt.id}"}
                navigate={~p"/supply-chain/receipts/#{receipt.id}"}
                class="text-link hover:underline"
              >
                GR {receipt.receipt_number}
              </.link>
            </:col>
            <:col :let={receipt} label="Kind">
              {Forms.label(receipt.kind)}
              <span :if={receipt.reverses_receipt_number} class="block text-xs text-ink-muted">
                of GR {receipt.reverses_receipt_number}
              </span>
            </:col>
            <:col :let={receipt} label="Order">PO {receipt.order_number}</:col>
            <:col :let={receipt} label="Received on">{Forms.date(receipt.received_on)}</:col>
            <:col :let={receipt} label="Lines">{length(receipt.lines)}</:col>
            <:col :let={receipt} label="Status">
              <.badge kind={Forms.status_kind(receipt.status)}>
                {Forms.label(receipt.status)}
              </.badge>
              <span :if={receipt.reversed_by_receipt_number} class="block text-xs text-ink-muted">
                reversed by GR {receipt.reversed_by_receipt_number}
              </span>
            </:col>
            <:empty
              :if={@receipts == []}
              title="No goods receipts here"
              reason={
                if @tab == "all",
                  do: "Receipts recorded against purchase orders appear here.",
                  else: "No receipt is #{Forms.label(@tab) |> String.downcase()}."
              }
            />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
