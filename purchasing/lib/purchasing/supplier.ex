defmodule Bilimbi.SupplyChain.Purchasing.Supplier do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # The address fields follow Core Address's shape (lines, locality, postcode,
  # country ISO code, first-level division code) so a later move to a shared
  # party record is a copy, not a translation.
  schema "supply_chain_purchasing_suppliers" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:contact_name, :string)
    field(:email, :string)
    field(:phone, :string)
    field(:address_line1, :string)
    field(:address_line2, :string)
    field(:address_line3, :string)
    field(:locality, :string)
    field(:postcode, :string)
    field(:country_iso, :string)
    field(:admin1_code, :string)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  @details [
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
    :active
  ]

  @doc "The fields `update_changeset/2` accepts."
  def detail_fields, do: @details

  def create_changeset(supplier, attributes) do
    supplier
    |> cast(attributes, [:code], empty_values: [""])
    |> update_change(:code, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code])
    |> validate_length(:code, min: 1, max: 50)
    |> details(attributes)
    |> unique_constraint(:code, name: :supply_chain_purchasing_suppliers_company_code_unique)
  end

  # The code is the supplier's identity: orders name it, so it never changes.
  def update_changeset(supplier, attributes), do: details(supplier, attributes)

  defp details(changeset_or_supplier, attributes) do
    changeset_or_supplier
    |> cast(attributes, @details, empty_values: [""])
    |> update_change(:name, &String.trim/1)
    |> update_change(:contact_name, &trim_to_nil/1)
    |> update_change(:email, &trim_to_nil/1)
    |> update_change(:phone, &trim_to_nil/1)
    |> update_change(:address_line1, &trim_to_nil/1)
    |> update_change(:address_line2, &trim_to_nil/1)
    |> update_change(:address_line3, &trim_to_nil/1)
    |> update_change(:locality, &trim_to_nil/1)
    |> update_change(:postcode, &trim_to_nil/1)
    |> update_change(:admin1_code, &trim_to_nil/1)
    |> update_change(:country_iso, &upcase_to_nil/1)
    |> validate_required([:name, :active])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:contact_name, max: 200)
    |> validate_length(:email, max: 255)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/)
    |> validate_length(:phone, max: 50)
    |> validate_length(:address_line1, max: 255)
    |> validate_length(:address_line2, max: 255)
    |> validate_length(:address_line3, max: 255)
    |> validate_length(:locality, max: 120)
    |> validate_length(:postcode, max: 20)
    |> validate_length(:admin1_code, max: 20)
    |> validate_format(:country_iso, ~r/^[A-Z]{2}$/)
  end

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp upcase_to_nil(value) when is_binary(value) do
    case value |> String.trim() |> String.upcase() do
      "" -> nil
      code -> code
    end
  end
end
