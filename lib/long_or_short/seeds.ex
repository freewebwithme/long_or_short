defmodule LongOrShort.Seeds do
  @moduledoc """
  Helpers for `priv/repo/seeds.exs`.
  """

  @doc """
  Extracts a comma-separated list of field names from an Ash error,
  without surfacing the rejected raw value.

  Ash's `InvalidArgument.message/1` calls `inspect(error.value)` directly,
  which leaks sensitive arguments (e.g. passwords) into stdout/logs even
  when the action argument is declared with `sensitive?: true`. Seed
  scripts surface registration failures, so they must format their own
  message rather than `Exception.message(error)`.
  """
  def invalid_fields(%{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(&Map.get(&1, :field))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> case do
      [] -> "(unknown)"
      fields -> Enum.join(fields, ", ")
    end
  end

  def invalid_fields(_), do: "(unknown)"
end
