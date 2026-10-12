defmodule Bilimbi.SupplyChain.Receiving.Receipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.SupplyChain.Receiving.ReceiptLine

  @statuses ~w(draft posted cancelled)
  @kinds ~w(receipt reversal)

  schema "supply_chain_receiving_receipts" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # The database assigns the number on insert (see the migration).
    field(:receipt_number, :integer, read_after_writes: true)
    field(:kind, :string, default: "receipt")
    field(:status, :string, default: "draft")
    field(:order_id, :integer)
    field(:order_number, :integer)
    field(:supplier_id, :integer)
    field(:reverses_receipt_id, :integer)
    field(:reason, :string)
    field(:received_on, :date)
    field(:supplier_reference, :string)
    field(:notes, :string)
    field(:created_by_user_id, :integer)
    field(:created_by_impersonator_id, :integer)
    field(:posted_by_user_id, :integer)
    field(:posted_by_impersonator_id, :integer)
    field(:posted_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    has_many(:lines, ReceiptLine, preload_order: [asc: :line_number])
    timestamps(type: :naive_datetime)
  end

  @doc "The statuses a goods receipt moves through."
  def statuses, do: @statuses

  @doc "The kinds of goods receipt: a receipt, or the reversal of one."
  def kinds, do: @kinds

  @doc "Casts the facts a person records on a draft: the date, the supplier's reference, notes."
  def changeset(receipt, attributes) do
    receipt
    |> cast(attributes, [:received_on, :supplier_reference, :notes], empty_values: [""])
    |> update_change(:supplier_reference, &trim_to_nil/1)
    |> update_change(:notes, &trim_to_nil/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :order_id,
      :order_number,
      :supplier_id,
      :received_on,
      :created_by_user_id
    ])
    |> validate_length(:supplier_reference, max: 100, count: :codepoints)
    |> validate_length(:notes, max: 1000, count: :codepoints)
  end

  def transition_changeset(receipt, status, changes) do
    receipt
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
