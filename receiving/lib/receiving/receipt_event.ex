defmodule Bilimbi.SupplyChain.Receiving.ReceiptEvent do
  @moduledoc false
  use Ecto.Schema

  # Append-only status history; the database stamps occurred_at.
  schema "supply_chain_receiving_receipt_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:receipt_id, :integer)
    field(:from_status, :string)
    field(:to_status, :string)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    field(:reason, :string)
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
  end
end
