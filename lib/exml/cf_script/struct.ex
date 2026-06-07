defmodule ExML.CFScript.Struct do
  @moduledoc """
  Case-insensitive, case-preserving map operations for CFML structs.

  CFML struct keys are matched case-insensitively but keep the original casing
  for iteration / `structKeyList` / `structKeyArray`. We model a struct as a
  plain Elixir map with original-case string keys and route access through these
  helpers, which compare keys by their downcased form.
  """

  @spec fetch(map(), String.t()) :: {:ok, any()} | :error
  def fetch(map, key) do
    down = downcase(key)

    case Enum.find(map, fn {k, _v} -> downcase(k) == down end) do
      {_k, v} -> {:ok, v}
      nil -> :error
    end
  end

  @spec get(map(), String.t(), any()) :: any()
  def get(map, key, default \\ nil) do
    case fetch(map, key) do
      {:ok, v} -> v
      :error -> default
    end
  end

  @spec has_key?(map(), String.t()) :: boolean()
  def has_key?(map, key) do
    down = downcase(key)
    Enum.any?(map, fn {k, _v} -> downcase(k) == down end)
  end

  # Set a key: update the existing (case-insensitively matched) key in place,
  # preserving its original casing; otherwise add it with the given casing.
  @spec put(map(), String.t(), any()) :: map()
  def put(map, key, value) do
    down = downcase(key)

    case Enum.find(map, fn {k, _v} -> downcase(k) == down end) do
      {existing, _v} -> Map.put(map, existing, value)
      nil -> Map.put(map, key, value)
    end
  end

  @spec delete(map(), String.t()) :: map()
  def delete(map, key) do
    down = downcase(key)
    keys = for {k, _v} <- map, downcase(k) == down, do: k
    Map.drop(map, keys)
  end

  @spec keys(map()) :: [String.t()]
  def keys(map), do: Map.keys(map)

  # Merge `source` into `target` (case-insensitively); `overwrite` decides
  # whether existing keys are replaced.
  @spec merge(map(), map(), boolean()) :: map()
  def merge(target, source, overwrite) do
    Enum.reduce(source, target, fn {k, v}, acc ->
      if not overwrite and has_key?(acc, k), do: acc, else: put(acc, k, v)
    end)
  end

  @spec downcase(any()) :: String.t()
  defp downcase(key) when is_binary(key), do: String.downcase(key)
  defp downcase(key), do: key |> to_string() |> String.downcase()
end
