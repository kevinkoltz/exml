defmodule ExML.CFScript.Query do
  @moduledoc """
  A CFML query value: ordered columns plus rows.

  Modelled after Lucee's `QueryImpl`. Column names are case-insensitive, so row
  data is keyed by the downcased column name while `columns` preserves the
  original casing for `columnList`. Rows are 1-based.

  This module is the pure functional core for query operations: builders/readers
  return a new `%Query{}` or a scalar. Reference-type mutation (queries are
  reference types in CFML) is layered on by `ExML.CFScript.Collections`, which
  writes a mutator's result back into the query's heap cell.
  """

  alias ExML.CFScript.{CFException, Struct, Value}

  @type t :: %__MODULE__{columns: [String.t()], rows: [%{optional(String.t()) => any()}]}
  defstruct columns: [], rows: []

  @doc "Build a query from a column list (comma string or array) and optional types/data."
  @spec new([String.t()] | String.t(), any(), any()) :: t()
  def new(column_names, _types \\ nil, data \\ nil) do
    columns = parse_columns(column_names)
    query = %__MODULE__{columns: columns, rows: []}
    if is_nil(data), do: query, else: populate(query, data)
  end

  @doc "Number of rows."
  @spec record_count(t()) :: non_neg_integer()
  def record_count(%__MODULE__{rows: rows}), do: length(rows)

  @doc "Number of columns."
  @spec column_count(t()) :: non_neg_integer()
  def column_count(%__MODULE__{columns: columns}), do: length(columns)

  @doc "Comma-delimited column list, preserving original case."
  @spec column_list(t()) :: String.t()
  def column_list(%__MODULE__{columns: columns}), do: Enum.join(columns, ",")

  @doc "Whether a column exists (case-insensitive)."
  @spec column?(t(), String.t()) :: boolean()
  def column?(%__MODULE__{} = query, name), do: down(name) in downcased(query)

  @doc "All values in a column, in row order."
  @spec column_data(t(), String.t()) :: [any()]
  def column_data(%__MODULE__{rows: rows} = query, name) do
    ensure_column!(query, name)
    key = down(name)
    Enum.map(rows, &Map.get(&1, key))
  end

  @doc "A row (1-based) as a struct map (downcased keys)."
  @spec get_row(t(), integer()) :: map()
  def get_row(%__MODULE__{rows: rows} = query, row) do
    case Enum.at(rows, row - 1) do
      nil ->
        raise CFException,
          message: "Query row [#{row}] out of range (recordCount #{record_count(query)})"

      r ->
        r
    end
  end

  @doc "Append a row from a struct map (missing columns become empty string)."
  @spec add_row(t(), map()) :: t()
  def add_row(%__MODULE__{columns: columns, rows: rows} = query, data) when is_map(data) do
    row = for col <- columns, into: %{}, do: {down(col), Struct.get(data, col, "")}
    %{query | rows: rows ++ [row]}
  end

  @doc "Append `n` empty rows."
  @spec add_rows(t(), integer()) :: t()
  def add_rows(%__MODULE__{columns: columns, rows: rows} = query, n) do
    empty = for col <- columns, into: %{}, do: {down(col), ""}
    %{query | rows: rows ++ List.duplicate(empty, n)}
  end

  @doc "Set a cell (1-based row); the column must exist."
  @spec set_cell(t(), String.t(), any(), integer()) :: t()
  def set_cell(%__MODULE__{rows: rows} = query, name, value, row) do
    ensure_column!(query, name)

    if row < 1 or row > record_count(query) do
      raise CFException,
        message: "Query row [#{row}] out of range (recordCount #{record_count(query)})"
    end

    updated = List.update_at(rows, row - 1, &Map.put(&1, down(name), value))
    %{query | rows: updated}
  end

  @doc "Add a column with optional initial values; existing rows are padded."
  @spec add_column(t(), String.t(), [any()]) :: t()
  def add_column(%__MODULE__{columns: columns, rows: rows} = query, name, values \\ []) do
    key = down(name)

    rows =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, i} -> Map.put(row, key, Enum.at(values, i, "")) end)

    %{query | columns: columns ++ [name], rows: rows}
  end

  @doc "Rows as a list of struct maps (for `queryExecute` returnType=\"array\")."
  @spec to_array(t()) :: [map()]
  def to_array(%__MODULE__{rows: rows}), do: rows

  @doc "Build a query from an executor result shaped like `Ecto.Repo.query/2`."
  @spec from_result(%{columns: [String.t()], rows: [[any()]]}) :: t()
  def from_result(%{columns: columns, rows: rows}) do
    keys = Enum.map(columns, &down/1)
    row_maps = Enum.map(rows, fn values -> keys |> Enum.zip(values) |> Map.new() end)
    %__MODULE__{columns: columns, rows: row_maps}
  end

  ## Helpers

  @spec populate(t(), any()) :: t()
  defp populate(query, data) when is_map(data), do: add_row(query, data)
  defp populate(query, data) when is_list(data), do: Enum.reduce(data, query, &add_row(&2, &1))

  @spec parse_columns([String.t()] | String.t()) :: [String.t()]
  defp parse_columns(names) when is_list(names), do: Enum.map(names, &Value.to_str/1)

  defp parse_columns(names) when is_binary(names) do
    names |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  @spec downcased(t()) :: [String.t()]
  defp downcased(%__MODULE__{columns: columns}), do: Enum.map(columns, &down/1)

  @spec ensure_column!(t(), String.t()) :: :ok
  defp ensure_column!(query, name) do
    unless column?(query, name) do
      raise CFException, message: "Column [#{name}] not found in query"
    end

    :ok
  end

  @spec down(String.t()) :: String.t()
  defp down(name), do: name |> Value.to_str() |> String.downcase()
end
