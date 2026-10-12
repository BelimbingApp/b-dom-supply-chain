defmodule Bilimbi.SupplyChain.Purchasing.Web.SuppliersLive do
  @moduledoc """
  The signed-in company's suppliers and tax codes, through the Purchasing
  facade. Viewing needs `supply-chain.purchasing.view`; adding and
  deactivating need `supply-chain.purchasing.configuration.manage`, which
  the facade checks again on every write.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.SupplyChain.Purchasing
  alias Bilimbi.SupplyChain.Purchasing.Web.Forms
  alias Bilimbi.SupplyChain.Purchasing.Web.Refusals

  @configure "supply-chain.purchasing.configuration.manage"
  @write_events ~w(save_supplier toggle_supplier save_tax_code toggle_tax_code)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Suppliers")
     |> assign(:active_nav, "supply_chain.suppliers")
     |> assign(:can_configure?, Authz.can(scope(socket), @configure).allowed)
     |> assign(:supplier_form, supplier_form(%{}))
     |> assign(:tax_code_form, tax_code_form(%{}))
     |> load()}
  end

  @impl true
  def handle_event(event, params, socket) when event in @write_events do
    socket = assign(socket, :can_configure?, Authz.can(scope(socket), @configure).allowed)

    if socket.assigns.can_configure? do
      handle_write(event, params, socket)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to configure purchasing.")}
    end
  end

  defp handle_write("save_supplier", %{"supplier" => params}, socket) do
    case Purchasing.create_supplier(scope(socket), company_id(socket), params) do
      {:ok, supplier} ->
        {:noreply,
         socket
         |> assign(:supplier_form, supplier_form(%{}))
         |> load()
         |> put_flash(:success, "Supplier #{supplier.code} added.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:supplier_form, supplier_form(params))
         |> put_flash(:error, Refusals.text(reason))}
    end
  end

  defp handle_write("toggle_supplier", %{"id" => id, "active" => active}, socket) do
    socket
    |> write(fn ->
      Purchasing.update_supplier(scope(socket), company_id(socket), Forms.integer(id), %{
        "active" => active
      })
    end)
    |> case do
      {:ok, socket, supplier} ->
        state = if supplier.active, do: "active", else: "inactive"
        {:noreply, put_flash(socket, :success, "Supplier #{supplier.code} is now #{state}.")}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  defp handle_write("save_tax_code", %{"tax_code" => params}, socket) do
    case Purchasing.create_tax_code(scope(socket), company_id(socket), params) do
      {:ok, tax_code} ->
        {:noreply,
         socket
         |> assign(:tax_code_form, tax_code_form(%{}))
         |> load()
         |> put_flash(:success, "Tax code #{tax_code.code} added.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:tax_code_form, tax_code_form(params))
         |> put_flash(:error, Refusals.text(reason))}
    end
  end

  defp handle_write("toggle_tax_code", %{"id" => id, "active" => active}, socket) do
    socket
    |> write(fn ->
      Purchasing.update_tax_code(scope(socket), company_id(socket), Forms.integer(id), %{
        "active" => active
      })
    end)
    |> case do
      {:ok, socket, tax_code} ->
        state = if tax_code.active, do: "active", else: "inactive"
        {:noreply, put_flash(socket, :success, "Tax code #{tax_code.code} is now #{state}.")}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  defp write(socket, fun) do
    case fun.() do
      {:ok, record} -> {:ok, load(socket), record}
      {:error, reason} -> {:error, socket |> load() |> put_flash(:error, Refusals.text(reason))}
    end
  end

  defp load(socket) do
    with {:ok, suppliers} <- Purchasing.list_suppliers(scope(socket), company_id(socket)),
         {:ok, tax_codes} <- Purchasing.list_tax_codes(scope(socket), company_id(socket)) do
      socket |> assign(:suppliers, suppliers) |> assign(:tax_codes, tax_codes)
    else
      {:error, _reason} -> socket |> assign(:suppliers, []) |> assign(:tax_codes, [])
    end
  end

  defp supplier_form(params) do
    to_form(
      Map.merge(
        %{
          "code" => "",
          "name" => "",
          "contact_name" => "",
          "email" => "",
          "phone" => "",
          "address_line1" => "",
          "address_line2" => "",
          "address_line3" => "",
          "locality" => "",
          "postcode" => "",
          "country_iso" => "",
          "admin1_code" => ""
        },
        params
      ),
      as: :supplier
    )
  end

  defp tax_code_form(params) do
    to_form(Map.merge(%{"code" => "", "name" => "", "rate" => ""}, params), as: :tax_code)
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="purchasing-suppliers" variant={:list}>
        <.header>
          Suppliers
          <:subtitle>
            The parties this company buys from, and the tax codes its orders price with.
          </:subtitle>
        </.header>

        <.card :if={@can_configure?} id="supplier-editor" title="New supplier" class="mt-5">
          <.form for={@supplier_form} id="supplier-form" phx-submit="save_supplier" class="p-4">
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input field={@supplier_form[:code]} label="Code" hint="Fixed once saved." />
              <.input field={@supplier_form[:name]} label="Name" />
              <.input field={@supplier_form[:contact_name]} label="Contact name" />
              <.input field={@supplier_form[:email]} type="email" label="Email" />
              <.input field={@supplier_form[:phone]} label="Phone" />
              <.input field={@supplier_form[:address_line1]} label="Address line 1" />
              <.input field={@supplier_form[:address_line2]} label="Address line 2" />
              <.input field={@supplier_form[:address_line3]} label="Address line 3" />
              <.input field={@supplier_form[:locality]} label="Locality" />
              <.input field={@supplier_form[:postcode]} label="Postcode" />
              <.input
                field={@supplier_form[:country_iso]}
                label="Country (ISO code)"
                hint="Two letters, such as the code Core Geonames lists."
              />
              <.input field={@supplier_form[:admin1_code]} label="Division code" />
            </div>
            <.button type="submit" variant="primary">Add supplier</.button>
          </.form>
        </.card>

        <.card id="suppliers" inner_class="p-0" class="mt-5">
          <.table id="suppliers-table" rows={@suppliers} caption="Suppliers" framed={false}>
            <:col :let={supplier} label="Code">{supplier.code}</:col>
            <:col :let={supplier} label="Name">{supplier.name}</:col>
            <:col :let={supplier} label="Contact">
              {supplier.contact_name || "—"}
              <span :if={supplier.email} class="block text-xs text-ink-muted">{supplier.email}</span>
            </:col>
            <:col :let={supplier} label="Location">
              {Enum.join(Enum.reject([supplier.locality, supplier.country_iso], &is_nil/1), ", ")}
            </:col>
            <:col :let={supplier} label="State">
              <.badge kind={if supplier.active, do: :success, else: :neutral}>
                {if supplier.active, do: "Active", else: "Inactive"}
              </.badge>
            </:col>
            <:action :let={supplier}>
              <.button
                :if={@can_configure?}
                id={"supplier-toggle-#{supplier.id}"}
                type="button"
                phx-click="toggle_supplier"
                phx-value-id={supplier.id}
                phx-value-active={to_string(not supplier.active)}
              >
                {if supplier.active, do: "Deactivate", else: "Activate"}
              </.button>
            </:action>
            <:empty
              :if={@suppliers == []}
              title="No suppliers yet"
              reason={
                if @can_configure?,
                  do: "Add the first supplier above.",
                  else: "An operator with the configuration permission adds suppliers."
              }
            />
          </.table>
        </.card>

        <.card :if={@can_configure?} id="tax-code-editor" title="New tax code" class="mt-5">
          <.form for={@tax_code_form} id="tax-code-form" phx-submit="save_tax_code" class="p-4">
            <div class="grid gap-x-4 sm:grid-cols-3">
              <.input field={@tax_code_form[:code]} label="Code" hint="Fixed once saved." />
              <.input field={@tax_code_form[:name]} label="Name" />
              <.input
                field={@tax_code_form[:rate]}
                label="Rate (%)"
                inputmode="decimal"
                hint="A line keeps the rate it was priced with."
              />
            </div>
            <.button type="submit" variant="primary">Add tax code</.button>
          </.form>
        </.card>

        <.card id="tax-codes" inner_class="p-0" class="mt-5">
          <.table id="tax-codes-table" rows={@tax_codes} caption="Tax codes" framed={false}>
            <:col :let={tax_code} label="Code">{tax_code.code}</:col>
            <:col :let={tax_code} label="Name">{tax_code.name}</:col>
            <:col :let={tax_code} label="Rate (%)" align={:right}>{Forms.money(tax_code.rate)}</:col>
            <:col :let={tax_code} label="State">
              <.badge kind={if tax_code.active, do: :success, else: :neutral}>
                {if tax_code.active, do: "Active", else: "Inactive"}
              </.badge>
            </:col>
            <:action :let={tax_code}>
              <.button
                :if={@can_configure?}
                id={"tax-code-toggle-#{tax_code.id}"}
                type="button"
                phx-click="toggle_tax_code"
                phx-value-id={tax_code.id}
                phx-value-active={to_string(not tax_code.active)}
              >
                {if tax_code.active, do: "Deactivate", else: "Activate"}
              </.button>
            </:action>
            <:empty
              :if={@tax_codes == []}
              title="No tax codes yet"
              reason="Order lines without a tax code carry no tax."
            />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
