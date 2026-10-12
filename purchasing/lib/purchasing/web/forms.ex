defmodule Bilimbi.SupplyChain.Purchasing.Web.Forms do
  @moduledoc false

  # Form helpers the purchasing pages share: a fixed number of blank line
  # rows on a create form, and the params those rows come back as.

  @line_rows 5

  @doc "How many line rows a create form offers."
  def line_rows, do: @line_rows

  @doc "The blank line rows a create form starts with."
  def blank_lines, do: for(index <- 0..(@line_rows - 1), do: {index, %{}})

  @doc """
  The lines a form posted, in row order, without rows whose description is
  blank. `lines` is the `%{"0" => %{...}, ...}` map a `lines[0][field]`
  naming scheme produces.
  """
  def lines_from_params(nil), do: []

  def lines_from_params(lines) when is_map(lines) do
    lines
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} -> row end)
    |> Enum.reject(&(String.trim(Map.get(&1, "description", "")) == ""))
  end

  @doc "The posted rows keyed by index, for re-rendering a refused form."
  def rows_from_params(nil), do: blank_lines()

  def rows_from_params(lines) when is_map(lines) do
    for index <- 0..(@line_rows - 1), do: {index, Map.get(lines, Integer.to_string(index), %{})}
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
  def money(nil), do: "—"
  def money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def money(value), do: to_string(value)

  @doc "A date rendered for a person."
  def date(nil), do: "—"
  def date(%Date{} = value), do: Date.to_iso8601(value)

  @doc "The badge kind a status renders with."
  def status_kind("draft"), do: :neutral
  def status_kind("submitted"), do: :warning
  def status_kind("approved"), do: :success
  def status_kind("sent"), do: :success
  def status_kind("partially_received"), do: :warning
  def status_kind("closed"), do: :neutral
  def status_kind("rejected"), do: :danger
  def status_kind("cancelled"), do: :danger
  def status_kind(_status), do: :neutral

  @doc "A status as a person reads it."
  def status_label(status), do: status |> String.replace("_", " ") |> String.capitalize()
end
