defmodule Bilimbi.SupplyChain.Purchasing.OrderAmendment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # Append-only; the database numbers each order's amendments and stamps
  # occurred_at.
  schema "supply_chain_purchasing_order_amendments" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:order_id, :integer)
    field(:amendment_number, :integer, read_after_writes: true)
    field(:reason, :string)
    field(:amended_by_user_id, :integer)
    field(:amended_by_impersonator_id, :integer)
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(amendment, attributes) do
    amendment
    |> cast(attributes, [:reason], empty_values: [""])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :order_id, :reason, :amended_by_user_id])
    |> validate_length(:reason, min: 1, max: 500, count: :codepoints)
  end
end
