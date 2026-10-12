defmodule Bilimbi.SupplyChain.Purchasing.Request do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.SupplyChain.Purchasing.RequestLine

  @statuses ~w(draft submitted approved rejected cancelled)

  schema "supply_chain_purchasing_requests" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # The database assigns the number on insert (see the migration).
    field(:request_number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:title, :string)
    field(:justification, :string)
    field(:needed_on, :date)
    field(:created_by_user_id, :integer)
    field(:created_by_impersonator_id, :integer)
    field(:submitted_by_user_id, :integer)
    field(:submitted_at, :utc_datetime_usec)
    field(:decided_by_user_id, :integer)
    field(:decided_at, :utc_datetime_usec)
    field(:decision_reason, :string)
    has_many(:lines, RequestLine, preload_order: [asc: :line_number])
    timestamps(type: :naive_datetime)
  end

  @doc "The statuses a purchase request moves through."
  def statuses, do: @statuses

  def changeset(request, attributes) do
    request
    |> cast(attributes, [:title, :justification, :needed_on], empty_values: [""])
    |> update_change(:title, &String.trim/1)
    |> update_change(:justification, &trim_to_nil/1)
    |> validate_required([:tenant_id, :company_id, :title, :created_by_user_id])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:justification, max: 1000)
  end

  def transition_changeset(request, status, changes) do
    request
    |> change(changes)
    |> put_change(:status, status)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:decision_reason, max: 500)
  end

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
