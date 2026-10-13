defmodule Bilimbi.SupplyChain.Receiving.Web.Forms do
  @moduledoc false

  # Form helpers the receiving pages share: the lines a receive form posts,
  # keyed by order line, and how a quantity, date, kind, or status renders.

  @doc """
  The lines a receive form posted, one per order line row with an accepted
  or rejected quantity, in order-line order. `lines` is the
  `%{"<order_line_id>" => %{...}, ...}` map a `receipt[lines][id][field]`
  naming scheme produces; a row whose quantities are both blank is left out.
  """
  def lines_from_params(nil), do: []

  def lines_from_params(lines) when is_map(lines) do
    for({id, row} <- lines, order_line_id = integer(id), is_map(row), do: {order_line_id, row})
    |> Enum.sort_by(fn {order_line_id, _row} -> order_line_id end)
    |> Enum.reject(fn {_order_line_id, row} ->
      blank?(row["received_quantity"]) and blank?(row["rejected_quantity"])
    end)
    |> Enum.map(fn {order_line_id, row} ->
      row
      |> Map.take(["received_quantity", "rejected_quantity", "rejection_reason"])
      |> Map.put("order_line_id", order_line_id)
    end)
  end

  @doc "The posted rows keyed by order line ID, for re-rendering a refused form."
  def rows_from_params(nil), do: %{}

  def rows_from_params(lines) when is_map(lines) do
    for({id, row} <- lines, order_line_id = integer(id), is_map(row), do: {order_line_id, row})
    |> Map.new()
  end

  @doc "An integer from a param, or `nil`."
  def integer(value) when is_integer(value), do: value

  def integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  def integer(_value), do: nil

  @doc "A decimal rendered for a person, without an exponent."
  def quantity(nil), do: "—"
  def quantity(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def quantity(value), do: to_string(value)

  @doc "A date rendered for a person."
  def date(nil), do: "—"
  def date(%Date{} = value), do: Date.to_iso8601(value)

  @doc "The badge kind a receipt status renders with."
  def status_kind("draft"), do: :neutral
  def status_kind("posted"), do: :success
  def status_kind("cancelled"), do: :danger
  def status_kind(_status), do: :neutral

  @doc "A status or kind as a person reads it."
  def label(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
