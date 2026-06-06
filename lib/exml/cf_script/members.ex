defmodule ExML.CFScript.Members do
  @moduledoc """
  Resolves CFML member-function calls (`value.name(args)`) to their built-in
  equivalents.

  CFML member functions are sugar over BIFs, with the target as the implicit
  first argument and a per-type name mapping:

    * strings  — `s.trim()` == `trim(s)` (member name == BIF name)
    * arrays   — `a.append(x)` == `arrayAppend(a, x)`, `a.map(fn)` == `arrayMap(a, fn)`
    * structs  — `s.keyExists(k)` == `structKeyExists(s, k)`, `s.each(fn)` == `structEach(s, fn)`

  Callback (UDF) members route to `ExML.CFScript.HigherOrder` with the supplied
  `invoke` function; everything else routes to `ExML.CFScript.BIF.Registry`.
  This module is the dispatch glue; it holds no interpreter state.
  """

  alias ExML.CFScript.{BIF.Registry, CFException, HigherOrder, Value}

  @type invoke :: (any(), [any()] -> any())

  # Array member name -> BIF name (only where they differ from "array" <> name).
  @array_aliases %{
    "len" => "arraylen",
    "size" => "arraylen",
    "isempty" => "arrayisempty",
    "tolist" => "arraytolist",
    "first" => "arrayfirst",
    "last" => "arraylast"
  }

  # Struct member name -> BIF name.
  @struct_aliases %{
    "keyexists" => "structkeyexists",
    "keyarray" => "structkeyarray",
    "keylist" => "structkeylist",
    "count" => "structcount",
    "len" => "structcount",
    "size" => "structcount",
    "isempty" => "structisempty"
  }

  @doc "Dispatch `value.name(args)`."
  @spec call(any(), String.t(), [any()], invoke()) :: any()
  def call(value, name, args, invoke) do
    down = String.downcase(name)

    cond do
      is_binary(value) -> Registry.call(down, [value | args])
      is_list(value) -> dispatch(prefix("array", down), value, args, invoke)
      is_map(value) and not is_struct(value) -> dispatch(prefix("struct", down), value, args, invoke)
      true -> raise CFException, message: "Cannot call member '#{name}' on #{Value.display(value)}"
    end
  end

  # Route to HigherOrder for UDF callbacks, otherwise to the BIF registry.
  @spec dispatch(String.t(), any(), [any()], invoke()) :: any()
  defp dispatch(bif_name, collection, args, invoke) do
    if HigherOrder.higher_order?(bif_name) do
      HigherOrder.call(bif_name, [collection | args], invoke)
    else
      Registry.call(bif_name, [collection | args])
    end
  end

  @spec prefix(String.t(), String.t()) :: String.t()
  defp prefix("array", name), do: Map.get(@array_aliases, name, "array" <> name)
  defp prefix("struct", name), do: Map.get(@struct_aliases, name, "struct" <> name)
end
