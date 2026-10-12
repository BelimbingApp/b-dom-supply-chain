defmodule Bilimbi.SupplyChain.Purchasing.RequestLine do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # numeric(20, 4): sixteen digits before the point.
  @quantity_limit Decimal.new("1E16")

  schema "supply_chain_purchasing_request_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:request_id, :integer)
    field(:line_number, :integer)
    field(:description, :string)
    field(:external_item_ref, :string)
    field(:quantity, :decimal)
    field(:unit, :string)
  end

  def changeset(line, attributes) do
    line
    |> cast(attributes, [:description, :external_item_ref, :quantity, :unit], empty_values: [""])
    |> update_change(:description, &String.trim/1)
    |> update_change(:external_item_ref, &trim_to_nil/1)
    |> update_change(:unit, &String.trim/1)
    |> validate_required([:line_number, :description, :quantity, :unit])
    |> validate_length(:description, min: 1, max: 500, count: :codepoints)
    |> validate_length(:external_item_ref, max: 100, count: :codepoints)
    |> validate_length(:unit, min: 1, max: 20, count: :codepoints)
    |> validate_number(:quantity, greater_than: 0, less_than: @quantity_limit)
    |> validate_scale(:quantity, 4)
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
