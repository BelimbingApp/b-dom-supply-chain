defmodule Bilimbi.SupplyChain.Purchasing.Order do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.SupplyChain.Purchasing.OrderLine

  @statuses ~w(draft submitted approved sent partially_received closed cancelled)

  schema "supply_chain_purchasing_orders" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # The database assigns the number on insert (see the migration).
    field(:order_number, :integer, read_after_writes: true)
    field(:purchase_request_id, :integer)
    field(:supplier_id, :integer)
    field(:currency_code, :string)
    field(:status, :string, default: "draft")
    field(:reference, :string)
    field(:notes, :string)
    field(:expected_on, :date)
    field(:amendment_count, :integer, default: 0)
    field(:created_by_user_id, :integer)
    field(:created_by_impersonator_id, :integer)
    field(:submitted_by_user_id, :integer)
    field(:submitted_at, :utc_datetime_usec)
    field(:approved_by_user_id, :integer)
    field(:approved_at, :utc_datetime_usec)
    field(:sent_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    has_many(:lines, OrderLine, preload_order: [asc: :line_number])
    timestamps(type: :naive_datetime)
  end

  @doc "The statuses a purchase order moves through."
  def statuses, do: @statuses

  @doc "Casts a draft's header: supplier, currency, and the amendable facts."
  def create_changeset(order, attributes) do
    order
    |> cast(attributes, [:supplier_id, :currency_code, :purchase_request_id], empty_values: [""])
    |> update_change(:currency_code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([
      :tenant_id,
      :company_id,
      :supplier_id,
      :currency_code,
      :created_by_user_id
    ])
    |> validate_format(:currency_code, ~r/^[A-Z]{3}$/)
    |> amendable_changeset(attributes)
  end

  @doc "Casts the facts an amendment may change: reference, notes, expected date."
  def amendable_changeset(order, attributes) do
    order
    |> cast(attributes, [:reference, :notes, :expected_on], empty_values: [""])
    |> update_change(:reference, &trim_to_nil/1)
    |> update_change(:notes, &trim_to_nil/1)
    |> validate_length(:reference, max: 100, count: :codepoints)
    |> validate_length(:notes, max: 1000, count: :codepoints)
  end

  def transition_changeset(order, status, changes) do
    order
    |> change(changes)
    |> put_change(:status, status)
    |> validate_inclusion(:status, @statuses)
  end

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
