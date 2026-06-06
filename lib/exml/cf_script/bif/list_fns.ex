defmodule ExML.CFScript.BIF.ListFns do
  @moduledoc """
  CFML list built-in functions, ported from Lucee 6.2.5
  (`lucee.runtime.type.util.ListUtil`).

  A CFML "list" is a delimited string. The delimiter argument is a *set* of
  single characters (each char delimits), defaulting to `,`. By default empty
  elements are ignored (`includeEmptyFields=false`), so `listLen("a,,b")` is 2.
  Element matching is case-sensitive and elements are not trimmed.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @default_delimiter ","

  @names ~w(
    listlen listfind listfindnocase listcontains listcontainsnocase
    listappend listprepend listtoarray listgetat listfirst listlast listrest
  )

  @impl true
  def names, do: @names

  @impl true
  def call("listlen", [list]), do: list |> elements(@default_delimiter) |> length()
  def call("listlen", [list, delim]), do: list |> elements(str(delim)) |> length()

  def call("listfind", [list, value]), do: index_of(list, value, @default_delimiter, &==/2)
  def call("listfind", [list, value, delim]), do: index_of(list, value, str(delim), &==/2)

  def call("listfindnocase", [list, value]), do: index_of(list, value, @default_delimiter, &iequals/2)
  def call("listfindnocase", [list, value, delim]), do: index_of(list, value, str(delim), &iequals/2)

  def call("listcontains", [list, value]), do: index_of(list, value, @default_delimiter, &contains/2)
  def call("listcontains", [list, value, delim]), do: index_of(list, value, str(delim), &contains/2)

  def call("listcontainsnocase", [list, value]), do: index_of(list, value, @default_delimiter, &icontains/2)

  def call("listappend", [list, value]), do: append(list, value, @default_delimiter)
  def call("listappend", [list, value, delim]), do: append(list, value, str(delim))

  def call("listprepend", [list, value]), do: prepend(list, value, @default_delimiter)
  def call("listprepend", [list, value, delim]), do: prepend(list, value, str(delim))

  def call("listtoarray", [list]), do: elements(list, @default_delimiter)
  def call("listtoarray", [list, delim]), do: elements(list, str(delim))

  def call("listgetat", [list, pos]), do: get_at(list, pos, @default_delimiter)
  def call("listgetat", [list, pos, delim]), do: get_at(list, pos, str(delim))

  def call("listfirst", [list]), do: first(list, @default_delimiter)
  def call("listfirst", [list, delim]), do: first(list, str(delim))

  def call("listlast", [list]), do: last(list, @default_delimiter)
  def call("listlast", [list, delim]), do: last(list, str(delim))

  def call("listrest", [list]), do: rest(list, @default_delimiter)
  def call("listrest", [list, delim]), do: rest(list, str(delim))

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  ## Helpers

  @spec str(any()) :: String.t()
  defp str(v), do: Value.to_str(v)

  # Split on any character in `delim`, dropping empty elements (the CFML default).
  @spec elements(any(), String.t()) :: [String.t()]
  defp elements(list, delim) do
    list
    |> str()
    |> String.split(String.graphemes(delim))
    |> Enum.reject(&(&1 == ""))
  end

  @spec index_of(any(), any(), String.t(), (String.t(), String.t() -> boolean())) :: non_neg_integer()
  defp index_of(list, value, delim, match?) do
    target = str(value)

    list
    |> elements(delim)
    |> Enum.find_index(&match?.(&1, target))
    |> case do
      nil -> 0
      i -> i + 1
    end
  end

  @spec append(any(), any(), String.t()) :: String.t()
  defp append(list, value, delim) do
    sep = primary(delim)

    case str(list) do
      "" -> str(value)
      l -> l <> sep <> str(value)
    end
  end

  @spec prepend(any(), any(), String.t()) :: String.t()
  defp prepend(list, value, delim) do
    sep = primary(delim)

    case str(list) do
      "" -> str(value)
      l -> str(value) <> sep <> l
    end
  end

  @spec get_at(any(), any(), String.t()) :: String.t()
  defp get_at(list, pos, delim) do
    items = elements(list, delim)
    i = trunc(Value.to_number(pos))

    case Enum.at(items, i - 1) do
      nil -> raise CFException, message: "invalid string list index [#{i}], indexes go from 1 to #{length(items)}"
      element -> element
    end
  end

  @spec first(any(), String.t()) :: String.t()
  defp first(list, delim), do: list |> elements(delim) |> List.first("")

  @spec last(any(), String.t()) :: String.t()
  defp last(list, delim), do: list |> elements(delim) |> List.last("")

  # listRest: the list with its first element removed, re-joined on the primary
  # delimiter.
  @spec rest(any(), String.t()) :: String.t()
  defp rest(list, delim) do
    case elements(list, delim) do
      [] -> ""
      [_first | tail] -> Enum.join(tail, primary(delim))
    end
  end

  @spec primary(String.t()) :: String.t()
  defp primary(delim), do: String.first(delim) || @default_delimiter

  @spec iequals(String.t(), String.t()) :: boolean()
  defp iequals(a, b), do: String.downcase(a) == String.downcase(b)

  @spec contains(String.t(), String.t()) :: boolean()
  defp contains(element, value), do: String.contains?(element, value)

  @spec icontains(String.t(), String.t()) :: boolean()
  defp icontains(element, value), do: String.contains?(String.downcase(element), String.downcase(value))
end
