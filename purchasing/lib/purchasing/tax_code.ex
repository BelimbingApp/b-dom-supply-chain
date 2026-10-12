defmodule Bilimbi.SupplyChain.Purchasing.TaxCode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # A company's tax codes are its configuration. A line snapshots the rate it
  # was priced with, so a later rate change leaves posted orders as they were.
  schema "supply_chain_purchasing_tax_codes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:rate, :decimal)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def create_changeset(tax_code, attributes) do
    tax_code
    |> cast(attributes, [:code], empty_values: [""])
    |> update_change(:code, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code])
    |> validate_length(:code, min: 1, max: 20, count: :codepoints)
    |> details(attributes)
    |> unique_constraint(:code, name: :supply_chain_purchasing_tax_codes_company_code_unique)
  end

  # The code is the tax code's identity; lines snapshot its rate, so the rate
  # may change for future orders.
  def update_changeset(tax_code, attributes), do: details(tax_code, attributes)

  defp details(changeset_or_tax_code, attributes) do
    changeset_or_tax_code
    |> cast(attributes, [:name, :rate, :active], empty_values: [""])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :rate, :active])
    |> validate_length(:name, min: 1, max: 120, count: :codepoints)
    |> validate_number(:rate, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_scale(:rate, 4)
  end

  defp validate_scale(changeset, field, places) do
    validate_change(changeset, field, fn ^field, value ->
      if Decimal.equal?(Decimal.round(value, places), value),
        do: [],
        else: [{field, "has more than #{places} decimal places"}]
    end)
  end
end
