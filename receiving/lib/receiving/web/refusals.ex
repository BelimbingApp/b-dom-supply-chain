defmodule Bilimbi.SupplyChain.Receiving.Web.Refusals do
  @moduledoc false

  # One reader-facing sentence for each refusal the facade returns, so the
  # pages do not drift apart in wording. A refusal names its real cause.
  @spec text(term()) :: String.t()
  def text(:unauthorized), do: "You no longer have permission to do that for this company."
  def text(:company_not_found), do: "That company is no longer available."
  def text(:company_archived), do: "This company is archived; nothing in it can change."
  def text(:receipt_not_found), do: "That goods receipt is no longer available."
  def text(:order_not_found), do: "That purchase order is no longer available."
  def text(:no_lines), do: "Enter a received or rejected quantity on at least one line."
  def text(:receipt_reversed), do: "This receipt was already reversed."

  def text(:reversal_not_reversible),
    do: "A reversal is not reversed; record the goods again with a new receipt."

  def text(:invalid_option), do: "That filter is not valid."

  def text({:order_not_receivable, status}),
    do:
      "This purchase order is #{String.replace(status, "_", " ")}; goods are received against a sent order."

  def text({:invalid_transition, status, _target}),
    do: "This receipt is #{String.replace(status, "_", " ")}, so that action no longer applies."

  def text(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, options} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _match, key ->
        options |> Keyword.get(String.to_existing_atom(key)) |> to_string()
      end)
    end)
    |> flatten_errors([])
    |> case do
      [] -> "Check the values entered."
      messages -> Enum.join(messages, " ")
    end
  end

  def text(_reason), do: "The action could not be completed."

  defp flatten_errors(errors, path) when is_map(errors) do
    Enum.flat_map(errors, fn {field, value} -> flatten_errors(value, path ++ [field]) end)
  end

  defp flatten_errors(errors, path) when is_list(errors) do
    Enum.flat_map(errors, fn
      message when is_binary(message) -> ["#{label(path)} #{message}."]
      nested -> flatten_errors(nested, path)
    end)
  end

  defp label(path),
    do:
      path |> Enum.map_join(" ", &to_string/1) |> String.replace("_", " ") |> String.capitalize()
end
