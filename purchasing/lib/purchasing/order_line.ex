defmodule Bilimbi.SupplyChain.Purchasing.OrderLine do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # numeric(20, 4): sixteen digits before the point.
  @amount_limit Decimal.new("1E16")

  schema "supply_chain_purchasing_order_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:order_id, :integer)
    field(:amendment_id, :integer)
    field(:superseded_by_amendment_id, :integer)
    field(:line_number, :integer)
    field(:description, :string)
    field(:external_item_ref, :string)
    field(:quantity, :decimal)
    field(:unit, :string)
    field(:unit_price, :decimal)
    field(:tax_code_id, :integer)
    field(:tax_rate, :decimal)
    field(:received_quantity, :decimal, default: Decimal.new(0))
  end

  @doc "The attributes a caller gives for one line."
  def fields, do: [:description, :external_item_ref, :quantity, :unit, :unit_price, :tax_code_id]

  def changeset(line, attributes) do
    line
    |> cast(attributes, fields(), empty_values: [""])
    |> update_change(:description, &String.trim/1)
    |> update_change(:external_item_ref, &trim_to_nil/1)
    |> update_change(:unit, &String.trim/1)
    |> validate_required([:line_number, :description, :quantity, :unit, :unit_price])
    |> validate_length(:description, min: 1, max: 500, count: :codepoints)
    |> validate_length(:external_item_ref, max: 100, count: :codepoints)
    |> validate_length(:unit, min: 1, max: 20, count: :codepoints)
    |> validate_number(:quantity, greater_than: 0, less_than: @amount_limit)
    |> validate_number(:unit_price, greater_than_or_equal_to: 0, less_than: @amount_limit)
    |> validate_scale(:quantity, 4)
    |> validate_scale(:unit_price, 4)
  end

  @doc """
  Casts a receipt against the line: the new received quantity, above what
  was received before and within the ordered quantity plus the tolerance
  (`ceiling`).
  """
  def receipt_changeset(line, received_quantity, ceiling) do
    line
    |> received_changeset(received_quantity)
    |> validate_number(:received_quantity, greater_than_or_equal_to: 0)
    |> validate_change(:received_quantity, fn :received_quantity, value ->
      cond do
        Decimal.gt?(value, ceiling) and Decimal.equal?(ceiling, line.quantity) ->
          [received_quantity: "exceeds the ordered quantity"]

        Decimal.gt?(value, ceiling) ->
          [received_quantity: "exceeds the ordered quantity and the tolerance"]

        Decimal.lt?(value, line.received_quantity) ->
          [received_quantity: "is below what was already received"]

        true ->
          []
      end
    end)
  end

  @doc "Casts a reversal against the line: the new received quantity, which stays at or above zero."
  def reversal_changeset(line, received_quantity) do
    line
    |> received_changeset(received_quantity)
    |> validate_number(:received_quantity,
      greater_than_or_equal_to: 0,
      message: "exceeds what was received"
    )
  end

  defp received_changeset(line, received_quantity) do
    line
    |> cast(%{received_quantity: received_quantity}, [:received_quantity])
    |> validate_required([:received_quantity])
    |> validate_scale(:received_quantity, 4)
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
