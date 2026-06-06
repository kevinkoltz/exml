defmodule ExML.CFScript.BIF.QueryFns do
  @moduledoc """
  CFML query built-in functions, ported from Lucee 6.2.5
  `lucee.runtime.functions.query.*`.

  These operate on the pure `ExML.CFScript.Query` value (the `Collections`
  boundary derefs the query reference first and, for the mutators, writes the
  result back). `valueList`/`valueArray` take a query *column*, which the
  interpreter has already evaluated to a list of that column's values.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Query, Value}

  @names ~w(
    querynew queryaddrow querysetcell queryaddcolumn querycolumndata
    querycolumnlist queryrecordcount querycolumncount querygetrow
    querycolumnexists queryisempty valuelist valuearray
  )

  @impl true
  def names, do: @names

  ## Builders / readers

  @impl true
  def call("querynew", [columns]), do: Query.new(columns)
  def call("querynew", [columns, types]), do: Query.new(columns, types)
  def call("querynew", [columns, types, data]), do: Query.new(columns, types, data)

  def call("queryrecordcount", [%Query{} = q]), do: Query.record_count(q)
  def call("querycolumncount", [%Query{} = q]), do: Query.column_count(q)
  def call("querycolumnlist", [%Query{} = q]), do: Query.column_list(q)
  def call("queryisempty", [%Query{} = q]), do: Query.record_count(q) == 0
  def call("querycolumnexists", [%Query{} = q, col]), do: Query.column?(q, Value.to_str(col))
  def call("querycolumndata", [%Query{} = q, col]), do: Query.column_data(q, Value.to_str(col))
  def call("querygetrow", [%Query{} = q, row]), do: Query.get_row(q, trunc(Value.to_number(row)))

  ## Mutators (pure: return the new query; Collections writes it back)

  def call("queryaddrow", [%Query{} = q]), do: Query.add_rows(q, 1)

  def call("queryaddrow", [%Query{} = q, data]) do
    if is_map(data),
      do: Query.add_row(q, data),
      else: Query.add_rows(q, trunc(Value.to_number(data)))
  end

  def call("querysetcell", [%Query{} = q, col, value]),
    do: Query.set_cell(q, Value.to_str(col), value, Query.record_count(q))

  def call("querysetcell", [%Query{} = q, col, value, row]),
    do: Query.set_cell(q, Value.to_str(col), value, trunc(Value.to_number(row)))

  def call("queryaddcolumn", [%Query{} = q, col]), do: Query.add_column(q, Value.to_str(col))

  def call("queryaddcolumn", [%Query{} = q, col, values]) when is_list(values),
    do: Query.add_column(q, Value.to_str(col), values)

  def call("queryaddcolumn", [%Query{} = q, col, _type, values]) when is_list(values),
    do: Query.add_column(q, Value.to_str(col), values)

  ## valueList / valueArray operate on a query column (already a list of values)

  def call("valuelist", [column]) when is_list(column), do: join(column, ",")

  def call("valuelist", [column, delim]) when is_list(column),
    do: join(column, Value.to_str(delim))

  def call("valuearray", [column]) when is_list(column), do: column

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  @spec join([any()], String.t()) :: String.t()
  defp join(values, delim), do: Enum.map_join(values, delim, &Value.to_str/1)
end
