defmodule Bilimbi.SupplyChain.Purchasing do
  @moduledoc """
  A company's purchasing: its suppliers and tax codes, its purchase requests,
  and its purchase orders with lines, approval, amendments, receipts, and an
  audited status history.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize
  `supply-chain.purchasing.view` and writes their own capability for the
  scope's signed-in actor and the target company at the moment they run,
  through `Bilimbi.Core.Company.authorize_company_target/3`: a system scope,
  a missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write then holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}` and one company's
  purchasing writes run one at a time.

  The database numbers each company's requests and orders 1, 2, 3, ... in
  creation order, so a number is never skipped or reused: a cancelled order
  keeps its number. Every creation and status transition writes a history
  row naming the actor (and any impersonator), the time the database
  recorded it, and the reason given; the database refuses a transition
  without one (see the migration). A draft is free to change. From
  submission on, an order's header and lines are fixed: an approved or sent
  order changes only through `amend_order/4`, which records an amendment
  and the lines it replaced, and a sent order's lines take received
  quantities only through `record_receipt/4` and give them back only
  through `reverse_receipt/4`. An amendment that changes a line, quantity,
  price, or tax sends the order back to `submitted` for a fresh approval by
  someone other than the amender.

  Results are plain maps; the schemas stay private to this module. Lines
  carry `line_total` (quantity times unit price) and `tax_amount` (from the
  tax rate snapshotted when the line was written), and an order carries
  their sums as `subtotal`, `tax_total`, and `total`, all decimals in the
  order's currency.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company

  alias Bilimbi.SupplyChain.Purchasing.{
    Order,
    OrderAmendment,
    OrderEvent,
    OrderLine,
    Request,
    RequestEvent,
    RequestLine,
    Supplier,
    TaxCode
  }

  alias Ecto.Changeset

  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"
  @manage_requests "supply-chain.purchasing.requests.manage"
  @approve_requests "supply-chain.purchasing.requests.approve"
  @manage_orders "supply-chain.purchasing.orders.manage"
  @approve_orders "supply-chain.purchasing.orders.approve"
  @receive_orders "supply-chain.purchasing.orders.receive"

  @default_limit 100
  @max_limit 500
  @hundred Decimal.new(100)

  @amendable_statuses ~w(approved sent)
  @receivable_statuses ~w(sent partially_received)
  @reversible_statuses ~w(partially_received closed)

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived
  @type transition_refusal :: {:invalid_transition, String.t(), String.t()}

  @doc "The capability every purchasing read asks for."
  def view_capability, do: @view

  @doc "The capability that maintains suppliers and tax codes."
  def configure_capability, do: @configure

  @doc "The capability that creates, submits, and cancels purchase requests."
  def manage_requests_capability, do: @manage_requests

  @doc "The capability that approves or rejects a submitted purchase request."
  def approve_requests_capability, do: @approve_requests

  @doc "The capability that creates, submits, sends, amends, closes, and cancels purchase orders."
  def manage_orders_capability, do: @manage_orders

  @doc "The capability that approves a submitted purchase order or returns it to draft."
  def approve_orders_capability, do: @approve_orders

  @doc "The capability that records or reverses goods received against a sent order; a Receiving module's seam."
  def receive_orders_capability, do: @receive_orders

  @doc "The statuses a purchase request moves through."
  @spec request_statuses() :: [String.t()]
  def request_statuses, do: Request.statuses()

  @doc "The statuses a purchase order moves through."
  @spec order_statuses() :: [String.t()]
  def order_statuses, do: Order.statuses()

  ## Suppliers

  @doc """
  The company's suppliers, ordered by code. Option `active: true` keeps only
  active ones.
  """
  @spec list_suppliers(Scope.t(), term(), keyword()) :: {:ok, [map()]} | {:error, refusal()}
  def list_suppliers(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       scope
       |> suppliers_query(company_id)
       |> active_filter(Keyword.get(options, :active))
       |> order_by([s], asc: s.code)
       |> Repo.all()
       |> Enum.map(&supplier_view/1)}
    end
  end

  @doc "One supplier of the company."
  @spec get_supplier(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :supplier_not_found}
  def get_supplier(%Scope{} = scope, company_id, supplier_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case supplier(scope, company_id, supplier_id) do
        nil -> {:error, :supplier_not_found}
        supplier -> {:ok, supplier_view(supplier)}
      end
    end
  end

  @doc """
  Adds a supplier: `code` (unique in the company, fixed for good), `name`,
  and optionally `contact_name`, `email`, `phone`, `address_line1` to
  `address_line3`, `locality`, `postcode`, `country_iso` (two upper-case
  letters), `admin1_code`, and `active`.
  """
  @spec create_supplier(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_supplier(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @configure, fn ->
      %Supplier{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> Supplier.create_changeset(attributes)
      |> Repo.insert()
      |> public_result(&supplier_view/1)
    end)
  end

  @doc """
  Changes a supplier's details or `active` flag. Its code never changes. An
  inactive supplier takes no new orders; its orders and history stay.
  """
  @spec update_supplier(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :supplier_not_found | Changeset.t()}
  def update_supplier(%Scope{} = scope, company_id, supplier_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @configure, fn ->
      case supplier(scope, company_id, supplier_id) do
        nil ->
          {:error, :supplier_not_found}

        supplier ->
          supplier
          |> Supplier.update_changeset(attributes)
          |> Repo.update()
          |> public_result(&supplier_view/1)
      end
    end)
  end

  ## Tax codes

  @doc """
  The company's tax codes, ordered by code. Option `active: true` keeps only
  active ones.
  """
  @spec list_tax_codes(Scope.t(), term(), keyword()) :: {:ok, [map()]} | {:error, refusal()}
  def list_tax_codes(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       scope
       |> tax_codes_query(company_id)
       |> active_filter(Keyword.get(options, :active))
       |> order_by([t], asc: t.code)
       |> Repo.all()
       |> Enum.map(&tax_code_view/1)}
    end
  end

  @doc """
  Adds a tax code: `code` (unique in the company, fixed for good), `name`,
  `rate` (a percentage from 0 to 100 with up to four decimal places), and
  optionally `active`. A line snapshots the rate it was written with.
  """
  @spec create_tax_code(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_tax_code(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @configure, fn ->
      %TaxCode{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> TaxCode.create_changeset(attributes)
      |> Repo.insert()
      |> public_result(&tax_code_view/1)
    end)
  end

  @doc "Changes a tax code's `name`, `rate`, or `active` flag; its code never changes."
  @spec update_tax_code(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :tax_code_not_found | Changeset.t()}
  def update_tax_code(%Scope{} = scope, company_id, tax_code_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @configure, fn ->
      case tax_code(scope, company_id, tax_code_id) do
        nil ->
          {:error, :tax_code_not_found}

        tax_code ->
          tax_code
          |> TaxCode.update_changeset(attributes)
          |> Repo.update()
          |> public_result(&tax_code_view/1)
      end
    end)
  end

  ## Purchase requests

  @doc """
  The company's purchase requests with their lines, newest number first.
  Options: `status` (one of `request_statuses/0`) and `limit` (1 to
  #{@max_limit}, default #{@default_limit}). A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec list_requests(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_requests(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, limit, status} <- list_options(options, Request.statuses()) do
      {:ok,
       scope
       |> requests_query(company_id)
       |> status_filter(status)
       |> order_by([r], desc: r.request_number)
       |> limit(^limit)
       |> preload(:lines)
       |> Repo.all()
       |> Enum.map(&request_view(&1, []))}
    end
  end

  @doc "One purchase request with its lines and its status history, oldest event first."
  @spec get_request(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :request_not_found}
  def get_request(%Scope{} = scope, company_id, request_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case request_with_lines(scope, company_id, request_id) do
        nil -> {:error, :request_not_found}
        request -> {:ok, request_view(request, request_events(scope, request))}
      end
    end
  end

  @doc """
  Creates a draft purchase request: `title`, optional `justification` and
  `needed_on`, and `lines`, each `%{description, quantity, unit}` with an
  optional `external_item_ref`. A draft may have no lines yet; submission
  needs at least one.
  """
  @spec create_request(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_request(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_requests, fn ->
      actor = actor(scope)
      lines = attributes |> fetch(:lines) |> List.wrap()

      %Request{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        created_by_user_id: actor.user_id,
        created_by_impersonator_id: actor.impersonator_id
      }
      |> Request.changeset(attributes)
      |> Changeset.put_assoc(:lines, request_line_changesets(scope, company_id, lines))
      |> Repo.insert()
      |> record_request_event(scope, nil, nil)
      |> public_result(&request_view(reload_request(scope, &1), request_events(scope, &1)))
    end)
  end

  @doc """
  Changes a draft request's `title`, `justification`, or `needed_on`, and
  replaces its lines when `lines` is given. A request that is no longer a
  draft is `{:error, {:invalid_transition, status, "draft"}}`.
  """
  @spec update_request(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :request_not_found | transition_refusal() | Changeset.t()}
  def update_request(%Scope{} = scope, company_id, request_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_requests, fn ->
      with {:ok, request} <- locked_request(scope, company_id, request_id),
           :ok <- require_status(request, "draft", "draft") do
        request
        |> Request.changeset(attributes)
        |> replace_lines(scope, fetch(attributes, :lines), fn lines ->
          request_line_changesets(scope, company_id, lines)
        end)
        |> Repo.update()
        |> public_result(&request_view(reload_request(scope, &1), request_events(scope, &1)))
      end
    end)
  end

  @doc "Submits a draft request for approval. It needs at least one line (`{:error, :no_lines}`)."
  @spec submit_request(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error, write_refusal() | :request_not_found | :no_lines | transition_refusal()}
  def submit_request(%Scope{} = scope, company_id, request_id) do
    write(scope, company_id, @manage_requests, fn ->
      with {:ok, request} <- locked_request(scope, company_id, request_id),
           :ok <- require_status(request, "draft", "submitted"),
           :ok <- require_lines(request) do
        actor = actor(scope)

        transition_request(scope, request, "submitted", nil,
          submitted_by_user_id: actor.user_id,
          submitted_at: DateTime.utc_now()
        )
      end
    end)
  end

  @doc """
  Approves a submitted request, with an optional `reason`. The approver is
  not the person who submitted it (`{:error, :own_request}`).
  """
  @spec approve_request(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :request_not_found
             | :own_request
             | transition_refusal()
             | Changeset.t()}
  def approve_request(%Scope{} = scope, company_id, request_id, attributes \\ %{})
      when is_map(attributes) do
    decide_request(scope, company_id, request_id, "approved", attributes, false)
  end

  @doc "Rejects a submitted request; a `reason` is required and the requester sees it."
  @spec reject_request(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :request_not_found
             | :own_request
             | transition_refusal()
             | Changeset.t()}
  def reject_request(%Scope{} = scope, company_id, request_id, attributes)
      when is_map(attributes) do
    decide_request(scope, company_id, request_id, "rejected", attributes, true)
  end

  @doc "Cancels a draft, submitted, or approved request; a `reason` is required."
  @spec cancel_request(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :request_not_found | transition_refusal() | Changeset.t()}
  def cancel_request(%Scope{} = scope, company_id, request_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_requests, fn ->
      with {:ok, request} <- locked_request(scope, company_id, request_id),
           :ok <- require_status(request, ~w(draft submitted approved), "cancelled"),
           {:ok, reason} <- required_reason(attributes) do
        transition_request(scope, request, "cancelled", reason, [])
      end
    end)
  end

  @doc """
  Creates a draft purchase order from an approved request: `supplier_id`,
  `currency_code`, and optionally `reference`, `notes`, `expected_on`, and
  `lines`. Without `lines`, the request's lines are copied with a unit price
  of zero to be priced on the draft. The order records
  `purchase_request_id`; a request may be ordered more than once, for
  example from two suppliers.
  """
  @spec create_order_from_request(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :request_not_found
             | :supplier_not_found
             | :supplier_inactive
             | transition_refusal()
             | Changeset.t()}
  def create_order_from_request(%Scope{} = scope, company_id, request_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_orders, fn ->
      with {:ok, request} <- locked_request(scope, company_id, request_id),
           :ok <- require_status(request, "approved", "ordered") do
        lines =
          case fetch(attributes, :lines) do
            nil ->
              Enum.map(request.lines, fn line ->
                %{
                  description: line.description,
                  external_item_ref: line.external_item_ref,
                  quantity: line.quantity,
                  unit: line.unit,
                  unit_price: Decimal.new(0)
                }
              end)

            lines ->
              lines
          end

        attributes =
          attributes
          |> Map.drop([:lines, "lines", :purchase_request_id, "purchase_request_id"])
          |> Map.put(:lines, lines)

        insert_order(scope, company_id, attributes, request.id)
      end
    end)
  end

  ## Purchase orders

  @doc """
  The company's purchase orders with their current lines and totals, newest
  number first. Options: `status` (one of `order_statuses/0`),
  `supplier_id`, and `limit` (1 to #{@max_limit}, default #{@default_limit}).
  A malformed option is `{:error, :invalid_option}`.
  """
  @spec list_orders(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_orders(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, limit, status} <- list_options(options, Order.statuses()),
         {:ok, supplier_id} <- supplier_option(options) do
      orders =
        scope
        |> orders_query(company_id)
        |> status_filter(status)
        |> supplier_filter(supplier_id)
        |> order_by([o], desc: o.order_number)
        |> limit(^limit)
        |> preload(lines: ^current_lines(scope))
        |> Repo.all()

      suppliers = suppliers_by_id(scope, company_id, Enum.map(orders, & &1.supplier_id))
      numbers = request_numbers(scope, company_id, Enum.map(orders, & &1.purchase_request_id))
      {:ok, Enum.map(orders, &order_view(&1, suppliers, numbers, [], []))}
    end
  end

  @doc """
  One purchase order: its header and supplier, current lines with totals,
  status history (oldest first), and amendments (oldest first), each with
  the lines it added and the IDs of the lines it superseded.
  """
  @spec get_order(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :order_not_found}
  def get_order(%Scope{} = scope, company_id, order_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case order_with_lines(scope, company_id, order_id) do
        nil -> {:error, :order_not_found}
        order -> {:ok, full_order_view(scope, order)}
      end
    end
  end

  @doc "The order with this `order_number` in the company, as `get_order/3` returns it."
  @spec find_order_by_number(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :order_not_found}
  def find_order_by_number(%Scope{} = scope, company_id, order_number) do
    with :ok <- authorize(scope, company_id, @view) do
      query =
        if is_integer(order_number),
          do: where(orders_query(scope, company_id), [o], o.order_number == ^order_number),
          else: where(orders_query(scope, company_id), false)

      case query |> preload(lines: ^current_lines(scope)) |> Repo.one() do
        nil -> {:error, :order_not_found}
        order -> {:ok, full_order_view(scope, order)}
      end
    end
  end

  @doc """
  One current or superseded order line with the facts another Domain
  matches against, such as a supplier's bill line in Finance payables: the
  line itself plus `order_id`, `order_number`, `order_status`,
  `supplier_id`, and `currency_code`.
  """
  @spec get_order_line(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :line_not_found}
  def get_order_line(%Scope{} = scope, company_id, line_id) do
    with :ok <- authorize(scope, company_id, @view) do
      query =
        if is_integer(line_id) do
          from(l in Tenancy.scope_query(OrderLine, scope),
            join: o in ^orders_query(scope, company_id),
            on: o.id == l.order_id,
            where: l.id == ^line_id,
            select: {l, o}
          )
        else
          where(Tenancy.scope_query(OrderLine, scope), false)
        end

      case Repo.one(query) do
        nil ->
          {:error, :line_not_found}

        {line, order} ->
          {:ok,
           line
           |> line_view()
           |> Map.merge(%{
             order_id: order.id,
             order_number: order.order_number,
             order_status: order.status,
             supplier_id: order.supplier_id,
             currency_code: order.currency_code
           })}
      end
    end
  end

  @doc """
  Creates a draft purchase order: `supplier_id` (an active supplier of the
  company), `currency_code` (three upper-case letters), optionally
  `reference`, `notes`, and `expected_on`, and `lines`, each
  `%{description, quantity, unit, unit_price}` with an optional
  `external_item_ref` and `tax_code_id` (an active tax code of the company,
  whose rate the line snapshots). A draft may have no lines yet; submission
  needs at least one.
  """
  @spec create_order(Scope.t(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :supplier_not_found | :supplier_inactive | Changeset.t()}
  def create_order(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_orders, fn ->
      insert_order(
        scope,
        company_id,
        Map.drop(attributes, [:purchase_request_id, "purchase_request_id"]),
        nil
      )
    end)
  end

  @doc """
  Changes a draft order's `supplier_id`, `currency_code`, `reference`,
  `notes`, or `expected_on`, and replaces its lines when `lines` is given.
  An order that is no longer a draft is
  `{:error, {:invalid_transition, status, "draft"}}`.
  """
  @spec update_order(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :order_not_found
             | :supplier_not_found
             | :supplier_inactive
             | transition_refusal()
             | Changeset.t()}
  def update_order(%Scope{} = scope, company_id, order_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, "draft", "draft"),
           changeset =
             Order.create_changeset(
               order,
               Map.drop(attributes, [:purchase_request_id, "purchase_request_id"])
             ),
           {:ok, changeset} <- validate_supplier(changeset, scope, company_id) do
        changeset
        |> replace_lines(scope, fetch(attributes, :lines), fn lines ->
          order_line_changesets(scope, company_id, lines, nil)
        end)
        |> Repo.update()
        |> public_result(&full_order_view(scope, reload_order(scope, &1)))
      end
    end)
  end

  @doc """
  Submits a draft order for approval. It needs at least one line
  (`{:error, :no_lines}`) and an active supplier (`{:error, :supplier_inactive}`).
  """
  @spec submit_order(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :order_not_found
             | :no_lines
             | :supplier_inactive
             | transition_refusal()}
  def submit_order(%Scope{} = scope, company_id, order_id) do
    write(scope, company_id, @manage_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, "draft", "submitted"),
           :ok <- require_lines(order),
           :ok <- require_active_supplier(scope, company_id, order.supplier_id) do
        actor = actor(scope)

        transition_order(scope, order, "submitted", nil,
          submitted_by_user_id: actor.user_id,
          submitted_at: DateTime.utc_now()
        )
      end
    end)
  end

  @doc """
  Approves a submitted order, with an optional `reason`. The approver is
  not the person who submitted it (`{:error, :own_order}`). From here on
  the order changes only through `amend_order/4`.
  """
  @spec approve_order(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :order_not_found
             | :own_order
             | transition_refusal()
             | Changeset.t()}
  def approve_order(%Scope{} = scope, company_id, order_id, attributes \\ %{})
      when is_map(attributes) do
    write(scope, company_id, @approve_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, "submitted", "approved"),
           :ok <- separate_duties(scope, order.submitted_by_user_id, :own_order),
           {:ok, reason} <- optional_reason(attributes) do
        actor = actor(scope)

        transition_order(scope, order, "approved", reason,
          approved_by_user_id: actor.user_id,
          approved_at: DateTime.utc_now()
        )
      end
    end)
  end

  @doc """
  Returns a submitted order to draft so it can be corrected and resubmitted;
  a `reason` is required. An order that was amended keeps its amendment
  trail, so it is approved or cancelled instead
  (`{:error, {:invalid_transition, "submitted", "draft"}}`).
  """
  @spec return_order(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :order_not_found | transition_refusal() | Changeset.t()}
  def return_order(%Scope{} = scope, company_id, order_id, attributes) when is_map(attributes) do
    write(scope, company_id, @approve_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, "submitted", "draft"),
           :ok <- require_unamended(order, "draft"),
           {:ok, reason} <- required_reason(attributes) do
        transition_order(scope, order, "draft", reason,
          submitted_by_user_id: nil,
          submitted_at: nil
        )
      end
    end)
  end

  @doc "Marks an approved order as sent to its supplier."
  @spec send_order(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, write_refusal() | :order_not_found | transition_refusal()}
  def send_order(%Scope{} = scope, company_id, order_id) do
    write(scope, company_id, @manage_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, "approved", "sent") do
        transition_order(scope, order, "sent", nil, sent_at: DateTime.utc_now())
      end
    end)
  end

  @doc """
  Closes a sent or partially received order, for example short of its
  ordered quantities; a `reason` is required. An order whose lines are all
  received closes by itself in `record_receipt/4`.
  """
  @spec close_order(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :order_not_found | transition_refusal() | Changeset.t()}
  def close_order(%Scope{} = scope, company_id, order_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, @receivable_statuses, "closed"),
           {:ok, reason} <- required_reason(attributes) do
        transition_order(scope, order, "closed", reason, closed_at: DateTime.utc_now())
      end
    end)
  end

  @doc """
  Cancels an order that is not closed or cancelled; a `reason` is required.
  Cancelling an order that was ever approved (approved, sent, partially
  received, or resubmitted by an amendment) also needs
  `supply-chain.purchasing.orders.approve`.
  """
  @spec cancel_order(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :order_not_found | transition_refusal() | Changeset.t()}
  def cancel_order(%Scope{} = scope, company_id, order_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <-
             require_status(
               order,
               ~w(draft submitted approved sent partially_received),
               "cancelled"
             ),
           :ok <- authorize_cancellation(scope, company_id, order),
           {:ok, reason} <- required_reason(attributes) do
        transition_order(scope, order, "cancelled", reason, cancelled_at: DateTime.utc_now())
      end
    end)
  end

  @doc """
  Amends an approved or sent order: records an amendment with its `reason`
  (required), replaces the current lines with `lines` (at least one, in the
  shape `create_order/3` takes), and applies any `reference`, `notes`, or
  `expected_on` given. The superseded lines stay on the order, marked with
  the amendment that replaced them, so the trail shows what was ordered
  before. A partially received order is closed short or cancelled instead
  (`{:error, {:invalid_transition, status, "amended"}}`).

  An amendment that changes any line (its description, item reference,
  quantity, unit, unit price, or tax) or the number of lines also returns
  the order to `submitted`, clearing its approval and sending date: it needs
  a fresh `approve_order/4` by someone other than the amender before it can
  be sent. One that changes only `reference`, `notes`, or `expected_on` leaves
  the status as it is.
  """
  @spec amend_order(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal() | :order_not_found | :no_lines | transition_refusal() | Changeset.t()}
  def amend_order(%Scope{} = scope, company_id, order_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, @amendable_statuses, "amended"),
           lines = attributes |> fetch(:lines) |> List.wrap(),
           :ok <- if(lines == [], do: {:error, :no_lines}, else: :ok),
           {:ok, amendment} <- insert_amendment(scope, order, attributes),
           {:ok, header} <- amend_header(order, attributes, amendment),
           {:ok, _count} <- supersede_lines(scope, order, amendment),
           {:ok, inserted} <- insert_lines(scope, company_id, order, lines, amendment.id) do
        if lines_changed?(order.lines, inserted) do
          actor = actor(scope)

          transition_order(scope, header, "submitted", amendment.reason,
            submitted_by_user_id: actor.user_id,
            submitted_at: DateTime.utc_now(),
            approved_by_user_id: nil,
            approved_at: nil,
            sent_at: nil
          )
        else
          {:ok, full_order_view(scope, reload_order(scope, order))}
        end
      end
    end)
  end

  @doc """
  Records goods received against a sent or partially received order:
  `lines`, each `%{line_id, quantity}` adding to that current line's
  received quantity. A line's received quantity never exceeds the ordered
  one unless `tolerance_percent` (0 to 100, up to four decimal places,
  default 0) allows it: the caller states the over-receipt tolerance the
  company configured, and the ceiling is the ordered quantity raised by that
  percentage. A sent order becomes partially received; an order whose
  current lines are all received in full (or over) closes. This is the seam
  a Receiving module calls; the goods receipt itself, and its match to the
  supplier's bill, are that module's records.
  """
  @spec record_receipt(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :order_not_found | transition_refusal() | Changeset.t()}
  def record_receipt(%Scope{} = scope, company_id, order_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @receive_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, @receivable_statuses, "received"),
           {:ok, tolerance} <- tolerance_option(attributes),
           {:ok, lines} <-
             apply_receipts(order, attributes |> fetch(:lines) |> List.wrap(), tolerance) do
        cond do
          Enum.all?(lines, &(Decimal.compare(&1.received_quantity, &1.quantity) != :lt)) ->
            transition_order(scope, order, "closed", "every line received in full",
              closed_at: DateTime.utc_now()
            )

          order.status == "sent" ->
            transition_order(scope, order, "partially_received", nil, [])

          true ->
            {:ok, full_order_view(scope, reload_order(scope, order))}
        end
      end
    end)
  end

  @doc """
  Takes back goods recorded as received against a partially received or
  closed order, when a receipt is reversed: `lines`, each
  `%{line_id, quantity}` subtracting from that current line's received
  quantity, which never goes below zero, and a `reason` (required). A
  closed order goes back to `partially_received` with the reason in its
  history, whether it closed on a full receipt or short; it is closed again
  through `close_order/4` or by a receipt that completes it. An order that
  has received nothing is `{:error, {:invalid_transition, status, "partially_received"}}`.
  This is the other half of the Receiving module's seam.
  """
  @spec reverse_receipt(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :order_not_found | transition_refusal() | Changeset.t()}
  def reverse_receipt(%Scope{} = scope, company_id, order_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @receive_orders, fn ->
      with {:ok, order} <- locked_order(scope, company_id, order_id),
           :ok <- require_status(order, @reversible_statuses, "partially_received"),
           {:ok, reason} <- required_reason(attributes),
           {:ok, order} <- reopen_order(scope, order, reason),
           {:ok, _lines} <- apply_reversals(order, attributes |> fetch(:lines) |> List.wrap()) do
        {:ok, full_order_view(scope, reload_order(scope, order))}
      end
    end)
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

  # Cancelling after approval undoes an approver's decision, so it takes the
  # approver's capability as well.
  defp authorize_cancellation(_scope, _company_id, %Order{status: status, amendment_count: 0})
       when status in ["draft", "submitted"],
       do: :ok

  defp authorize_cancellation(scope, company_id, _order),
    do: authorize(scope, company_id, @approve_orders)

  # `authorize/3` already refused a scope without a signed-in user.
  defp actor(scope) do
    %Actor{type: :user} = actor = Scope.actor(scope)
    %{user_id: actor.user_id, impersonator_id: actor.impersonator_id}
  end

  defp separate_duties(scope, user_id, refusal) do
    if actor(scope).user_id == user_id, do: {:error, refusal}, else: :ok
  end

  defp public_result({:ok, record}, view), do: {:ok, view.(record)}
  defp public_result(error, _view), do: error

  ## Requests

  defp decide_request(scope, company_id, request_id, status, attributes, reason_required?) do
    write(scope, company_id, @approve_requests, fn ->
      with {:ok, request} <- locked_request(scope, company_id, request_id),
           :ok <- require_status(request, "submitted", status),
           :ok <- separate_duties(scope, request.submitted_by_user_id, :own_request),
           {:ok, reason} <-
             if(reason_required?,
               do: required_reason(attributes),
               else: optional_reason(attributes)
             ) do
        actor = actor(scope)

        transition_request(scope, request, status, reason,
          decided_by_user_id: actor.user_id,
          decided_at: DateTime.utc_now(),
          decision_reason: reason
        )
      end
    end)
  end

  defp transition_request(scope, request, status, reason, changes) do
    from = request.status

    request
    |> Request.transition_changeset(status, changes)
    |> Repo.update()
    |> record_request_event(scope, from, reason)
    |> public_result(&request_view(reload_request(scope, &1), request_events(scope, &1)))
  end

  defp record_request_event({:ok, request}, scope, from, reason) do
    actor = actor(scope)

    with {:ok, _event} <-
           Repo.insert(%RequestEvent{
             tenant_id: request.tenant_id,
             company_id: request.company_id,
             request_id: request.id,
             from_status: from,
             to_status: request.status,
             actor_user_id: actor.user_id,
             actor_impersonator_id: actor.impersonator_id,
             reason: reason
           }) do
      {:ok, request}
    end
  end

  defp record_request_event(error, _scope, _from, _reason), do: error

  defp request_line_changesets(scope, company_id, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} ->
      %RequestLine{tenant_id: Scope.tenant_id(scope), company_id: company_id, line_number: number}
      |> RequestLine.changeset(if(is_map(line), do: line, else: %{}))
    end)
  end

  defp locked_request(scope, company_id, request_id) when is_integer(request_id) do
    case scope
         |> requests_query(company_id)
         |> where([r], r.id == ^request_id)
         |> lock("FOR UPDATE")
         |> preload(:lines)
         |> Repo.one() do
      nil -> {:error, :request_not_found}
      request -> {:ok, request}
    end
  end

  defp locked_request(_scope, _company_id, _request_id), do: {:error, :request_not_found}

  defp request_with_lines(scope, company_id, request_id) when is_integer(request_id) do
    scope
    |> requests_query(company_id)
    |> where([r], r.id == ^request_id)
    |> preload(:lines)
    |> Repo.one()
  end

  defp request_with_lines(_scope, _company_id, _request_id), do: nil

  defp reload_request(scope, request),
    do: request_with_lines(scope, request.company_id, request.id)

  defp request_events(scope, request) do
    from(e in Tenancy.scope_query(RequestEvent, scope),
      where: e.company_id == ^request.company_id and e.request_id == ^request.id,
      order_by: [asc: e.id]
    )
    |> Repo.all()
    |> Enum.map(&event_view/1)
  end

  ## Orders

  defp insert_order(scope, company_id, attributes, request_id) do
    actor = actor(scope)
    lines = attributes |> fetch(:lines) |> List.wrap()

    changeset =
      %Order{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        purchase_request_id: request_id,
        created_by_user_id: actor.user_id,
        created_by_impersonator_id: actor.impersonator_id
      }
      |> Order.create_changeset(Map.drop(attributes, [:lines, "lines"]))

    with {:ok, changeset} <- validate_supplier(changeset, scope, company_id) do
      changeset
      |> Changeset.put_assoc(:lines, order_line_changesets(scope, company_id, lines, nil))
      |> Repo.insert()
      |> record_order_event(scope, nil, nil)
      |> public_result(&full_order_view(scope, reload_order(scope, &1)))
    end
  end

  # A supplier named on a draft is an active supplier of this company. The
  # company lock serializes this with deactivation.
  defp validate_supplier(changeset, scope, company_id) do
    case Changeset.get_field(changeset, :supplier_id) do
      nil ->
        {:ok, changeset}

      supplier_id ->
        case supplier(scope, company_id, supplier_id) do
          nil -> {:error, :supplier_not_found}
          %Supplier{active: false} -> {:error, :supplier_inactive}
          %Supplier{} -> {:ok, changeset}
        end
    end
  end

  defp require_active_supplier(scope, company_id, supplier_id) do
    case supplier(scope, company_id, supplier_id) do
      %Supplier{active: true} -> :ok
      _supplier -> {:error, :supplier_inactive}
    end
  end

  # Each line names at most one active tax code of this company and
  # snapshots its rate.
  defp order_line_changesets(scope, company_id, lines, amendment_id) do
    tax_codes =
      scope
      |> tax_codes_query(company_id)
      |> where([t], t.active == true)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} ->
      %OrderLine{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        line_number: number,
        amendment_id: amendment_id
      }
      |> OrderLine.changeset(if(is_map(line), do: line, else: %{}))
      |> snapshot_tax_rate(tax_codes)
    end)
  end

  defp snapshot_tax_rate(changeset, tax_codes) do
    case Changeset.get_field(changeset, :tax_code_id) do
      nil ->
        Changeset.put_change(changeset, :tax_rate, nil)

      tax_code_id ->
        case Map.get(tax_codes, tax_code_id) do
          nil ->
            Changeset.add_error(
              changeset,
              :tax_code_id,
              "is not an active tax code of this company"
            )

          tax_code ->
            Changeset.put_change(changeset, :tax_rate, tax_code.rate)
        end
    end
  end

  # A draft's lines are replaced whole: the old rows go, the new ones come
  # in through the association so their errors report per line. The parent's
  # loaded lines are detached first: `put_assoc/3` would otherwise raise on
  # replacing children it was handed.
  defp replace_lines(changeset, _scope, nil, _build), do: changeset

  defp replace_lines(changeset, scope, lines, build) do
    line_changesets = build.(List.wrap(lines))
    record = changeset.data

    if Enum.all?(line_changesets, & &1.valid?) do
      {_count, nil} = record.lines |> Enum.map(& &1.id) |> delete_lines(scope, record)

      changeset
      |> Map.put(:data, %{record | lines: []})
      |> Changeset.put_assoc(:lines, line_changesets)
    else
      lines_error(record, line_changesets)
    end
  end

  defp delete_lines([], _scope, _record), do: {0, nil}

  defp delete_lines(ids, scope, %Request{}) do
    Repo.delete_all(from(l in Tenancy.scope_query(RequestLine, scope), where: l.id in ^ids))
  end

  defp delete_lines(ids, scope, %Order{}) do
    Repo.delete_all(from(l in Tenancy.scope_query(OrderLine, scope), where: l.id in ^ids))
  end

  # An invalid changeset carrying each line's errors under `lines`. The
  # lines are detached from their rows so the parent reports them as new.
  defp lines_error(record, line_changesets) do
    detached =
      Enum.map(line_changesets, fn changeset ->
        %{changeset | data: struct(changeset.data.__struct__), action: nil}
      end)

    %{record | lines: []}
    |> Changeset.change()
    |> Changeset.put_assoc(:lines, detached)
    |> Map.put(:valid?, false)
  end

  defp transition_order(scope, order, status, reason, changes) do
    from = order.status

    order
    |> Order.transition_changeset(status, changes)
    |> Repo.update()
    |> record_order_event(scope, from, reason)
    |> public_result(&full_order_view(scope, reload_order(scope, &1)))
  end

  defp record_order_event({:ok, order}, scope, from, reason) do
    actor = actor(scope)

    with {:ok, _event} <-
           Repo.insert(%OrderEvent{
             tenant_id: order.tenant_id,
             company_id: order.company_id,
             order_id: order.id,
             from_status: from,
             to_status: order.status,
             actor_user_id: actor.user_id,
             actor_impersonator_id: actor.impersonator_id,
             reason: reason
           }) do
      {:ok, order}
    end
  end

  defp record_order_event(error, _scope, _from, _reason), do: error

  # A closed order takes a reversal only as partially received again; the
  # lines change after the transition, which the line rules read.
  defp reopen_order(_scope, %Order{status: "partially_received"} = order, _reason),
    do: {:ok, order}

  defp reopen_order(scope, %Order{status: "closed"} = order, reason) do
    order
    |> Order.transition_changeset("partially_received", closed_at: nil)
    |> Repo.update()
    |> record_order_event(scope, "closed", reason)
    |> case do
      {:ok, reopened} -> {:ok, %{reopened | lines: order.lines}}
      error -> error
    end
  end

  defp insert_amendment(scope, order, attributes) do
    actor = actor(scope)

    %OrderAmendment{
      tenant_id: order.tenant_id,
      company_id: order.company_id,
      order_id: order.id,
      amended_by_user_id: actor.user_id,
      amended_by_impersonator_id: actor.impersonator_id
    }
    |> OrderAmendment.changeset(attributes)
    |> Repo.insert()
  end

  defp amend_header(order, attributes, amendment) do
    order
    |> Order.amendable_changeset(attributes)
    |> Changeset.put_change(:amendment_count, amendment.amendment_number)
    |> Repo.update()
  end

  defp supersede_lines(scope, order, amendment) do
    {count, nil} =
      from(l in Tenancy.scope_query(OrderLine, scope),
        where: l.order_id == ^order.id and is_nil(l.superseded_by_amendment_id)
      )
      |> Repo.update_all(set: [superseded_by_amendment_id: amendment.id])

    {:ok, count}
  end

  defp insert_lines(scope, company_id, order, lines, amendment_id) do
    changesets = order_line_changesets(scope, company_id, lines, amendment_id)

    if Enum.all?(changesets, & &1.valid?) do
      changesets
      |> Enum.map(&Changeset.put_change(&1, :order_id, order.id))
      |> Enum.reduce_while({:ok, []}, fn changeset, {:ok, inserted} ->
        case Repo.insert(changeset) do
          {:ok, line} -> {:cont, {:ok, [line | inserted]}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
      |> case do
        {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
        error -> error
      end
    else
      {:error, lines_error(order, changesets)}
    end
  end

  # What an approver agreed to: the lines, their quantities, prices, and tax.
  defp lines_changed?(before, current) do
    length(before) != length(current) or
      before |> Enum.zip(current) |> Enum.any?(fn {old, new} -> line_changed?(old, new) end)
  end

  defp line_changed?(old, new) do
    terms = [:description, :external_item_ref, :unit, :tax_code_id]

    Map.take(old, terms) != Map.take(new, terms) or
      not same_amount?(old.quantity, new.quantity) or
      not same_amount?(old.unit_price, new.unit_price) or
      not same_amount?(old.tax_rate, new.tax_rate)
  end

  defp same_amount?(nil, nil), do: true
  defp same_amount?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp same_amount?(_a, _b), do: false

  # Each receipt names a current line and adds to what it has received, up
  # to the ordered quantity raised by the tolerance.
  defp apply_receipts(order, receipts, tolerance) do
    apply_quantities(order, receipts, fn line, received ->
      ceiling =
        line.quantity
        |> Decimal.mult(Decimal.add(@hundred, tolerance))
        |> Decimal.div(@hundred)

      OrderLine.receipt_changeset(line, Decimal.add(line.received_quantity, received), ceiling)
    end)
  end

  # Each reversal names a current line and takes back part of what it received.
  defp apply_reversals(order, reversals) do
    apply_quantities(order, reversals, fn line, received ->
      OrderLine.reversal_changeset(line, Decimal.sub(line.received_quantity, received))
    end)
  end

  defp apply_quantities(order, receipts, change) do
    current = Map.new(order.lines, &{&1.id, &1})

    changesets =
      Enum.map(receipts, fn receipt ->
        receipt = if is_map(receipt), do: receipt, else: %{}
        line_id = fetch(receipt, :line_id)
        quantity = fetch(receipt, :quantity)

        case Map.get(current, line_id) do
          nil ->
            Changeset.add_error(
              Changeset.change(%OrderLine{}),
              :line_id,
              "is not a current line of this order"
            )

          line ->
            quantity_changeset(line, quantity, change)
        end
      end)

    cond do
      changesets == [] ->
        {:error, lines_refusal(order, "needs at least one receipt")}

      duplicate_receipts?(receipts) ->
        {:error, lines_refusal(order, "can name each line only once")}

      Enum.all?(changesets, & &1.valid?) ->
        changesets
        |> Enum.reduce_while({:ok, []}, fn changeset, {:ok, updated} ->
          case Repo.update(changeset) do
            {:ok, line} -> {:cont, {:ok, [line | updated]}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end
        end)
        |> case do
          {:ok, updated} ->
            received = Map.new(updated, &{&1.id, &1})
            {:ok, Enum.map(order.lines, &Map.get(received, &1.id, &1))}

          error ->
            error
        end

      true ->
        {:error, lines_error(order, changesets)}
    end
  end

  defp duplicate_receipts?(receipts) do
    line_ids = Enum.map(receipts, &if(is_map(&1), do: fetch(&1, :line_id)))
    length(line_ids) != length(Enum.uniq(line_ids))
  end

  defp lines_refusal(order, message) do
    %{order | lines: []} |> Changeset.change() |> Changeset.add_error(:lines, message)
  end

  defp quantity_changeset(line, quantity, change) do
    changeset = Changeset.cast(%OrderLine{}, %{quantity: quantity}, [:quantity])

    case Changeset.get_change(changeset, :quantity) do
      %Decimal{} = received ->
        if Decimal.gt?(received, 0),
          do: change.(line, received),
          else: Changeset.add_error(Changeset.change(line), :quantity, "must be greater than 0")

      _other ->
        Changeset.add_error(Changeset.change(line), :quantity, "is invalid")
    end
  end

  # The over-receipt tolerance the caller states: a percentage from 0 to
  # 100 with up to four decimal places, as a tolerance setting stores it.
  defp tolerance_option(attributes) do
    changeset =
      {%{}, %{tolerance_percent: :decimal}}
      |> Changeset.cast(%{tolerance_percent: fetch(attributes, :tolerance_percent)}, [
        :tolerance_percent
      ])
      |> Changeset.validate_number(:tolerance_percent,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )
      |> Changeset.validate_change(:tolerance_percent, fn :tolerance_percent, value ->
        if Decimal.equal?(Decimal.round(value, 4), value),
          do: [],
          else: [tolerance_percent: "has more than 4 decimal places"]
      end)

    if changeset.valid?,
      do: {:ok, Changeset.get_field(changeset, :tolerance_percent) || Decimal.new(0)},
      else: {:error, changeset}
  end

  defp locked_order(scope, company_id, order_id) when is_integer(order_id) do
    case scope
         |> orders_query(company_id)
         |> where([o], o.id == ^order_id)
         |> lock("FOR UPDATE")
         |> preload(lines: ^current_lines(scope))
         |> Repo.one() do
      nil -> {:error, :order_not_found}
      order -> {:ok, order}
    end
  end

  defp locked_order(_scope, _company_id, _order_id), do: {:error, :order_not_found}

  defp order_with_lines(scope, company_id, order_id) when is_integer(order_id) do
    scope
    |> orders_query(company_id)
    |> where([o], o.id == ^order_id)
    |> preload(lines: ^current_lines(scope))
    |> Repo.one()
  end

  defp order_with_lines(_scope, _company_id, _order_id), do: nil

  defp reload_order(scope, order), do: order_with_lines(scope, order.company_id, order.id)

  defp full_order_view(scope, order) do
    suppliers = suppliers_by_id(scope, order.company_id, [order.supplier_id])
    numbers = request_numbers(scope, order.company_id, [order.purchase_request_id])

    events =
      from(e in Tenancy.scope_query(OrderEvent, scope),
        where: e.company_id == ^order.company_id and e.order_id == ^order.id,
        order_by: [asc: e.id]
      )
      |> Repo.all()
      |> Enum.map(&event_view/1)

    order_view(order, suppliers, numbers, events, amendment_views(scope, order))
  end

  defp amendment_views(scope, order) do
    amendments =
      from(a in Tenancy.scope_query(OrderAmendment, scope),
        where: a.company_id == ^order.company_id and a.order_id == ^order.id,
        order_by: [asc: a.amendment_number]
      )
      |> Repo.all()

    if amendments == [] do
      []
    else
      lines =
        from(l in Tenancy.scope_query(OrderLine, scope),
          where: l.order_id == ^order.id,
          where: not is_nil(l.amendment_id) or not is_nil(l.superseded_by_amendment_id),
          order_by: [asc: l.id]
        )
        |> Repo.all()

      Enum.map(amendments, fn amendment ->
        amendment
        |> Map.take([
          :id,
          :amendment_number,
          :reason,
          :amended_by_user_id,
          :amended_by_impersonator_id,
          :occurred_at
        ])
        |> Map.put(
          :lines,
          lines |> Enum.filter(&(&1.amendment_id == amendment.id)) |> Enum.map(&line_view/1)
        )
        |> Map.put(
          :superseded_line_ids,
          lines
          |> Enum.filter(&(&1.superseded_by_amendment_id == amendment.id))
          |> Enum.map(& &1.id)
        )
      end)
    end
  end

  ## Validation helpers

  defp require_status(%{status: status}, allowed, _target)
       when is_binary(allowed) and status == allowed,
       do: :ok

  defp require_status(%{status: status}, allowed, target) when is_binary(allowed),
    do: {:error, {:invalid_transition, status, target}}

  defp require_status(%{status: status} = record, allowed, target) when is_list(allowed) do
    if status in allowed, do: :ok, else: require_status(record, "", target)
  end

  defp require_unamended(%{amendment_count: 0}, _target), do: :ok

  defp require_unamended(%{status: status}, target),
    do: {:error, {:invalid_transition, status, target}}

  defp require_lines(%{lines: []}), do: {:error, :no_lines}
  defp require_lines(_record), do: :ok

  defp required_reason(attributes) do
    case fetch(attributes, :reason) do
      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" ->
            reason_error("can't be blank")

          trimmed ->
            bounded_reason(trimmed)
        end

      nil ->
        reason_error("can't be blank")

      _other ->
        reason_error("is invalid")
    end
  end

  defp optional_reason(attributes) do
    case fetch(attributes, :reason) do
      nil ->
        {:ok, nil}

      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" ->
            {:ok, nil}

          trimmed ->
            bounded_reason(trimmed)
        end

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

  defp list_options(options, statuses) do
    limit = Keyword.get(options, :limit, @default_limit)
    status = Keyword.get(options, :status)

    if is_integer(limit) and limit in 1..@max_limit and (is_nil(status) or status in statuses),
      do: {:ok, limit, status},
      else: {:error, :invalid_option}
  end

  defp supplier_option(options) do
    case Keyword.get(options, :supplier_id) do
      nil -> {:ok, nil}
      id when is_integer(id) and id > 0 -> {:ok, id}
      _other -> {:error, :invalid_option}
    end
  end

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))

  ## Queries

  defp suppliers_query(scope, company_id),
    do: from(s in Tenancy.scope_query(Supplier, scope), where: s.company_id == ^company_id)

  defp supplier(scope, company_id, supplier_id) when is_integer(supplier_id),
    do: scope |> suppliers_query(company_id) |> where([s], s.id == ^supplier_id) |> Repo.one()

  defp supplier(_scope, _company_id, _supplier_id), do: nil

  defp suppliers_by_id(_scope, _company_id, []), do: %{}

  defp suppliers_by_id(scope, company_id, ids) do
    scope
    |> suppliers_query(company_id)
    |> where([s], s.id in ^Enum.uniq(ids))
    |> Repo.all()
    |> Map.new(&{&1.id, supplier_view(&1)})
  end

  defp request_numbers(scope, company_id, ids) do
    case ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        scope
        |> requests_query(company_id)
        |> where([r], r.id in ^ids)
        |> select([r], {r.id, r.request_number})
        |> Repo.all()
        |> Map.new()
    end
  end

  defp tax_codes_query(scope, company_id),
    do: from(t in Tenancy.scope_query(TaxCode, scope), where: t.company_id == ^company_id)

  defp tax_code(scope, company_id, tax_code_id) when is_integer(tax_code_id),
    do: scope |> tax_codes_query(company_id) |> where([t], t.id == ^tax_code_id) |> Repo.one()

  defp tax_code(_scope, _company_id, _tax_code_id), do: nil

  defp requests_query(scope, company_id),
    do: from(r in Tenancy.scope_query(Request, scope), where: r.company_id == ^company_id)

  defp orders_query(scope, company_id),
    do: from(o in Tenancy.scope_query(Order, scope), where: o.company_id == ^company_id)

  defp current_lines(scope) do
    from(l in Tenancy.scope_query(OrderLine, scope),
      where: is_nil(l.superseded_by_amendment_id),
      order_by: [asc: l.line_number]
    )
  end

  defp active_filter(query, true), do: where(query, [r], r.active == true)
  defp active_filter(query, _any), do: query

  defp status_filter(query, nil), do: query
  defp status_filter(query, status), do: where(query, [r], r.status == ^status)

  defp supplier_filter(query, nil), do: query
  defp supplier_filter(query, supplier_id), do: where(query, [o], o.supplier_id == ^supplier_id)

  ## Views

  defp supplier_view(supplier) do
    Map.take(supplier, [
      :id,
      :code,
      :name,
      :contact_name,
      :email,
      :phone,
      :address_line1,
      :address_line2,
      :address_line3,
      :locality,
      :postcode,
      :country_iso,
      :admin1_code,
      :active,
      :inserted_at,
      :updated_at
    ])
  end

  defp tax_code_view(tax_code), do: Map.take(tax_code, [:id, :code, :name, :rate, :active])

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

  defp request_view(request, events) do
    request
    |> Map.take([
      :id,
      :request_number,
      :status,
      :title,
      :justification,
      :needed_on,
      :created_by_user_id,
      :created_by_impersonator_id,
      :submitted_by_user_id,
      :submitted_at,
      :decided_by_user_id,
      :decided_at,
      :decision_reason,
      :inserted_at,
      :updated_at
    ])
    |> Map.put(
      :lines,
      Enum.map(
        request.lines,
        &Map.take(&1, [:id, :line_number, :description, :external_item_ref, :quantity, :unit])
      )
    )
    |> Map.put(:events, events)
  end

  defp order_view(order, suppliers, numbers, events, amendments) do
    lines = Enum.map(order.lines, &line_view/1)
    subtotal = sum(lines, :line_total)
    tax_total = sum(lines, :tax_amount)

    order
    |> Map.take([
      :id,
      :order_number,
      :status,
      :purchase_request_id,
      :supplier_id,
      :currency_code,
      :reference,
      :notes,
      :expected_on,
      :amendment_count,
      :created_by_user_id,
      :created_by_impersonator_id,
      :submitted_by_user_id,
      :submitted_at,
      :approved_by_user_id,
      :approved_at,
      :sent_at,
      :closed_at,
      :cancelled_at,
      :inserted_at,
      :updated_at
    ])
    |> Map.merge(%{
      supplier: Map.get(suppliers, order.supplier_id),
      purchase_request_number: Map.get(numbers, order.purchase_request_id),
      lines: lines,
      subtotal: subtotal,
      tax_total: tax_total,
      total: Decimal.add(subtotal, tax_total),
      events: events,
      amendments: amendments
    })
  end

  defp line_view(line) do
    line_total = Decimal.mult(line.quantity, line.unit_price)

    tax_amount =
      case line.tax_rate do
        nil -> Decimal.new(0)
        rate -> line_total |> Decimal.mult(rate) |> Decimal.div(@hundred)
      end

    line
    |> Map.take([
      :id,
      :line_number,
      :description,
      :external_item_ref,
      :quantity,
      :unit,
      :unit_price,
      :tax_code_id,
      :tax_rate,
      :received_quantity,
      :amendment_id,
      :superseded_by_amendment_id
    ])
    |> Map.merge(%{line_total: line_total, tax_amount: tax_amount})
  end

  defp sum(rows, field),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(Map.fetch!(&1, field), &2))
end
