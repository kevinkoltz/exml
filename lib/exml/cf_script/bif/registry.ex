defmodule ExML.CFScript.BIF.Registry do
  @moduledoc """
  Aggregates the `ExML.CFScript.BIF` family modules into a single
  case-insensitive name → family-module lookup, built once at compile time.

  Each family's `names/0` returns plain strings, so the table is a literal map
  (string → module atom) baked into the module — no per-call rebuilding and no
  anonymous functions in module attributes.
  """

  alias ExML.CFScript.BIF.{ArrayFns, DecisionFns, ListFns, StringFns, StructFns}

  @families [StringFns, DecisionFns, ListFns, ArrayFns, StructFns]

  @table (for family <- @families,
              name <- family.names(),
              into: %{},
              do: {name, family})

  @doc "Whether `name` is a registered BIF (case-insensitive)."
  @spec builtin?(String.t()) :: boolean()
  def builtin?(name), do: Map.has_key?(@table, String.downcase(name))

  @doc """
  Dispatch `name` to its owning family. Raises `ExML.CFScript.CFException` if no
  family owns it.
  """
  @spec call(String.t(), [any()]) :: any()
  def call(name, args) do
    down = String.downcase(name)

    case Map.fetch(@table, down) do
      {:ok, family} -> family.call(down, args)
      :error -> raise ExML.CFScript.CFException, message: "Undefined function: #{name}"
    end
  end

  @doc "All registered BIF names (sorted) — useful for diagnostics."
  @spec names() :: [String.t()]
  def names, do: @table |> Map.keys() |> Enum.sort()
end
