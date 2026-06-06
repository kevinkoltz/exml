defmodule ExML.CFScript.BIF.ArrayFns do
  @moduledoc """
  CFML array built-in functions (the non-callback ones), ported from Lucee
  6.2.5 `lucee.runtime.functions.arrays.*`. Arrays are 1-based Elixir lists.

  These functions are pure and value-returning (a mutator returns the new
  list). Reference-type mutation is layered on by `ExML.CFScript.Collections`,
  which writes a mutator's result back into the receiver's heap cell and
  returns `true`, exactly as Lucee does. Callback functions
  (`arrayMap`/`arrayFilter`/...) live in `ExML.CFScript.HigherOrder` because
  they need the interpreter to invoke a UDF.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @names ~w(
    arraylen arraynew arrayisempty arrayappend arrayprepend arraytolist
    arraycontains arrayfind arrayfindnocase arrayslice arrayreverse
    arrayfirst arraylast arraysum arrayavg arraymax arraymin
    arraydeleteat arrayinsertat arrayset arrayclear
  )

  @impl true
  def names, do: @names

  @impl true
  def call("arraylen", [arr]) when is_list(arr), do: length(arr)
  def call("arraynew", _args), do: []
  def call("arrayisempty", [arr]) when is_list(arr), do: arr == []

  def call("arrayappend", [arr, value]) when is_list(arr), do: arr ++ [value]
  def call("arrayprepend", [arr, value]) when is_list(arr), do: [value | arr]

  def call("arraytolist", [arr]) when is_list(arr), do: join(arr, ",")
  def call("arraytolist", [arr, delim]) when is_list(arr), do: join(arr, Value.to_str(delim))

  # arrayFind: case-sensitive exact match, 1-based index, 0 if absent.
  def call("arrayfind", [arr, value]) when is_list(arr), do: index_of(arr, value, &equal_cs?/2)

  def call("arrayfindnocase", [arr, value]) when is_list(arr),
    do: index_of(arr, value, &Value.equals?/2)

  def call("arraycontains", [arr, value]) when is_list(arr),
    do: index_of(arr, value, &equal_cs?/2)

  def call("arrayreverse", [arr]) when is_list(arr), do: Enum.reverse(arr)

  # arrayFirst/arrayLast error on an empty array, as Lucee does.
  def call("arrayfirst", [arr]) when is_list(arr), do: first(arr)
  def call("arraylast", [arr]) when is_list(arr), do: last(arr)

  def call("arraysum", [arr]) when is_list(arr), do: arr |> numbers() |> Enum.sum()
  def call("arraymax", [arr]) when is_list(arr), do: arr |> numbers() |> Enum.max()
  def call("arraymin", [arr]) when is_list(arr), do: arr |> numbers() |> Enum.min()

  def call("arrayavg", [arr]) when is_list(arr) do
    nums = numbers(arr)
    if nums == [], do: 0, else: Enum.sum(nums) / length(nums)
  end

  # arraySlice(arr, offset[, length]) — Lucee ArraySlice.java (1-based offset;
  # length 0 = to end; negative offset/length count from the end).
  def call("arrayslice", [arr, offset]) when is_list(arr),
    do: slice(arr, trunc(Value.to_number(offset)), 0)

  def call("arrayslice", [arr, offset, length]) when is_list(arr),
    do: slice(arr, trunc(Value.to_number(offset)), trunc(Value.to_number(length)))

  ## Mutators (pure: return the new list; the Collections boundary writes it
  ## back into the reference and returns true). 1-based indexes.

  def call("arrayclear", [arr]) when is_list(arr), do: []

  def call("arraydeleteat", [arr, pos]) when is_list(arr) do
    i = trunc(Value.to_number(pos))

    if i < 1 or i > length(arr),
      do: raise(CFException, message: "arrayDeleteAt: index [#{i}] out of range")

    List.delete_at(arr, i - 1)
  end

  def call("arrayinsertat", [arr, pos, value]) when is_list(arr) do
    i = trunc(Value.to_number(pos))

    if i < 1 or i > length(arr) + 1,
      do: raise(CFException, message: "arrayInsertAt: index [#{i}] out of range")

    List.insert_at(arr, i - 1, value)
  end

  # arraySet(arr, from, to, value): set every slot in [from, to], extending the
  # array (with empty strings, like Lucee's null-less fill) as needed.
  def call("arrayset", [arr, from, to, value]) when is_list(arr) do
    f = trunc(Value.to_number(from))
    t = trunc(Value.to_number(to))

    if f < 1,
      do:
        raise(CFException,
          message: "Start index of the function arraySet must be greater than zero; now [#{f}]"
        )

    if f > t,
      do:
        raise(CFException,
          message: "End index of the function arraySet must be greater than the Start index"
        )

    extended = extend(arr, t)
    Enum.reduce(f..t, extended, fn i, acc -> List.replace_at(acc, i - 1, value) end)
  end

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  ## Helpers

  @spec join([any()], String.t()) :: String.t()
  defp join(arr, delim), do: Enum.map_join(arr, delim, &Value.to_str/1)

  @spec numbers([any()]) :: [number()]
  defp numbers(arr), do: Enum.map(arr, &Value.to_number/1)

  # Pad a list up to `size` with empty strings (Lucee has no nulls by default).
  @spec extend([any()], non_neg_integer()) :: [any()]
  defp extend(arr, size) when length(arr) >= size, do: arr
  defp extend(arr, size), do: arr ++ List.duplicate("", size - length(arr))

  @spec index_of([any()], any(), (any(), any() -> boolean())) :: non_neg_integer()
  defp index_of(arr, value, match?) do
    case Enum.find_index(arr, &match?.(&1, value)) do
      nil -> 0
      i -> i + 1
    end
  end

  # Case-sensitive equality: numeric when both numeric, else exact string match.
  @spec equal_cs?(any(), any()) :: boolean()
  defp equal_cs?(a, b) do
    case {Value.as_number(a), Value.as_number(b)} do
      {{:ok, na}, {:ok, nb}} -> na == nb
      _ -> Value.to_str(a) == Value.to_str(b)
    end
  end

  @spec first([any()]) :: any()
  defp first([]), do: raise(CFException, message: "arrayFirst: array cannot be empty")
  defp first([h | _]), do: h

  @spec last([any()]) :: any()
  defp last([]), do: raise(CFException, message: "arrayLast: array cannot be empty")
  defp last(arr), do: List.last(arr)

  @spec slice([any()], integer(), integer()) :: [any()]
  defp slice([], _offset, _len),
    do: raise(CFException, message: "arraySlice: array cannot be empty")

  defp slice(arr, offset, len) do
    size = length(arr)
    off = if offset > 0, do: offset, else: size + offset

    cond do
      off < 1 or off > size ->
        raise CFException, message: "arraySlice: offset [#{offset}] out of range"

      len > 0 ->
        Enum.slice(arr, off - 1, len)

      len < 0 ->
        to = size + len
        Enum.slice(arr, (off - 1)..(to - 1)//1)

      true ->
        Enum.slice(arr, (off - 1)..(size - 1)//1)
    end
  end
end
