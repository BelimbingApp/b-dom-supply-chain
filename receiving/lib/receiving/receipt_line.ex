defmodule Bilimbi.SupplyChain.Receiving.ReceiptLine do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # numeric(20, 4): sixteen digits before the point.
  @amount_limit Decimal.new("1E16")

  schema "supply_chain_receiving_receipt_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:receipt_id, :integer)
    field(:line_number, :integer)
    field(:order_line_id, :integer)
    # Copied from the order line when the receipt is written and again when
    # it is posted, so a receipt reads the same whatever the order becomes.
    field(:order_line_number, :integer)
    field(:description, :string)
    field(:unit, :string)
    field(:ordered_quantity, :decimal)
    field(:received_quantity, :decimal, default: Decimal.new(0))
    field(:rejected_quantity, :decimal, default: Decimal.new(0))
    field(:rejection_reason, :string)
  end

  @doc "The attributes a caller gives for one line."
  def fields, do: [:order_line_id, :received_quantity, :rejected_quantity, :rejection_reason]

  @doc "Casts a caller's line; `order_line` is the current order line it names."
  def changeset(line, attributes, order_line) do
    line
    |> cast(attributes, fields(), empty_values: [""])
    |> update_change(:rejection_reason, &trim_to_nil/1)
    |> put_snapshot(order_line)
    |> validate_required([:line_number, :order_line_id, :received_quantity, :rejected_quantity])
    |> validate_number(:received_quantity, greater_than_or_equal_to: 0, less_than: @amount_limit)
    |> validate_number(:rejected_quantity, greater_than_or_equal_to: 0, less_than: @amount_limit)
    |> validate_scale(:received_quantity, 4)
    |> validate_scale(:rejected_quantity, 4)
    |> validate_length(:rejection_reason, max: 500, count: :codepoints)
    |> validate_quantities()
  end

  defp put_snapshot(changeset, nil),
    do: add_error(changeset, :order_line_id, "is not a current line of this order")

  defp put_snapshot(changeset, order_line) do
    change(changeset,
      order_line_number: order_line.line_number,
      description: order_line.description,
      unit: order_line.unit,
      ordered_quantity: order_line.quantity
    )
  end

  defp validate_quantities(changeset) do
    received = get_field(changeset, :received_quantity)
    rejected = get_field(changeset, :rejected_quantity)
    reason = get_field(changeset, :rejection_reason)

    cond do
      not changeset.valid? ->
        changeset

      Decimal.equal?(Decimal.add(received, rejected), 0) ->
        add_error(
          changeset,
          :received_quantity,
          "or the rejected quantity must be greater than 0"
        )

      Decimal.gt?(rejected, 0) and is_nil(reason) ->
        add_error(changeset, :rejection_reason, "can't be blank when goods are rejected")

      Decimal.equal?(rejected, 0) and not is_nil(reason) ->
        add_error(changeset, :rejection_reason, "applies only to rejected goods")

      true ->
        changeset
    end
  end

  defp validate_scale(changeset, field, places) do
    validate_change(changeset, field, fn ^field, value ->
      if Decimal.equal?(Decimal.round(value, places), value),
        do: [],
        else: [{field, "has more than #{places} decimal places"}]
    end)
  end

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
