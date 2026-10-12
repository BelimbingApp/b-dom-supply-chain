defmodule Bilimbi.SupplyChain.Receiving.Setting do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # Append-only: each row is one version of a company's receiving settings,
  # the newest being current. The database stamps occurred_at.
  schema "supply_chain_receiving_settings" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:over_receipt_tolerance_percent, :decimal)
    field(:set_by_user_id, :integer)
    field(:set_by_impersonator_id, :integer)
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(setting, attributes) do
    setting
    |> cast(attributes, [:over_receipt_tolerance_percent], empty_values: [""])
    |> validate_required([
      :tenant_id,
      :company_id,
      :over_receipt_tolerance_percent,
      :set_by_user_id
    ])
    |> validate_number(:over_receipt_tolerance_percent,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_change(:over_receipt_tolerance_percent, fn field, value ->
      if Decimal.equal?(Decimal.round(value, 4), value),
        do: [],
        else: [{field, "has more than 4 decimal places"}]
    end)
  end
end
