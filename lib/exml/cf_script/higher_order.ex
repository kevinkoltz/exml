defmodule ExML.CFScript.HigherOrder do
  @moduledoc """
  CFML higher-order collection functions — the ones that take a UDF callback
  (`arrayMap`, `arrayFilter`, `arrayReduce`, `arrayEach`, `arraySome`,
  `arrayEvery`, and the `struct*` equivalents).

  These live outside the `ExML.CFScript.BIF` families because invoking a UDF
  needs the interpreter. The caller passes an `invoke` function
  `(callable, arg_values -> result)`; this module stays free of interpreter
  internals (functional core), and the interpreter supplies the effectful
  invoker (imperative shell).

  Array callbacks receive `(element, index)` (1-based index); reduce receives
  `(accumulator, element, index)`. Struct callbacks receive `(key, value)`.
  Extra arguments are ignored by closures that declare fewer parameters.
  """

  alias ExML.CFScript.Value

  @array_names ~w(arraymap arrayfilter arrayreduce arrayeach arraysome arrayevery)
  @struct_names ~w(structeach structmap structfilter structreduce)

  @type invoke :: (any(), [any()] -> any())

  @doc "Whether `name` is a higher-order collection function (case-insensitive)."
  @spec higher_order?(String.t()) :: boolean()
  def higher_order?(name), do: String.downcase(name) in @array_names ++ @struct_names

  @doc "Dispatch a higher-order function by name with `[collection, udf | rest]`."
  @spec call(String.t(), [any()], invoke()) :: any()
  def call("arraymap", [list, udf], invoke) do
    list |> with_index() |> Enum.map(fn {el, i} -> invoke.(udf, [el, i]) end)
  end

  def call("arrayfilter", [list, udf], invoke) do
    list
    |> with_index()
    |> Enum.filter(fn {el, i} -> Value.truthy?(invoke.(udf, [el, i])) end)
    |> Enum.map(&elem(&1, 0))
  end

  def call("arrayreduce", [list, udf, initial], invoke) do
    list
    |> with_index()
    |> Enum.reduce(initial, fn {el, i}, acc -> invoke.(udf, [acc, el, i]) end)
  end

  def call("arrayreduce", [list, udf], invoke), do: call("arrayreduce", [list, udf, nil], invoke)

  def call("arrayeach", [list, udf], invoke) do
    list |> with_index() |> Enum.each(fn {el, i} -> invoke.(udf, [el, i]) end)
    nil
  end

  def call("arraysome", [list, udf], invoke) do
    list |> with_index() |> Enum.any?(fn {el, i} -> Value.truthy?(invoke.(udf, [el, i])) end)
  end

  def call("arrayevery", [list, udf], invoke) do
    list |> with_index() |> Enum.all?(fn {el, i} -> Value.truthy?(invoke.(udf, [el, i])) end)
  end

  def call("structeach", [struct, udf], invoke) do
    Enum.each(struct, fn {k, v} -> invoke.(udf, [k, v]) end)
    nil
  end

  def call("structmap", [struct, udf], invoke) do
    for {k, v} <- struct, into: %{}, do: {k, invoke.(udf, [k, v])}
  end

  def call("structfilter", [struct, udf], invoke) do
    for {k, v} <- struct, Value.truthy?(invoke.(udf, [k, v])), into: %{}, do: {k, v}
  end

  def call("structreduce", [struct, udf, initial], invoke) do
    Enum.reduce(struct, initial, fn {k, v}, acc -> invoke.(udf, [acc, k, v]) end)
  end

  @spec with_index([any()]) :: [{any(), pos_integer()}]
  defp with_index(list), do: Enum.with_index(list, 1)
end
