defmodule ExML.CFScript.BIF.StructFns do
  @moduledoc """
  CFML struct built-in functions. Structs are modelled as Elixir maps with
  original-case string keys; lookups go through `ExML.CFScript.Struct`, which
  matches keys case-insensitively (CFML structs are case-insensitive but
  case-preserving).
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Struct, Value}

  @names ~w(
    structkeyexists structnew structcount structisempty structkeyarray
    structkeylist structinsert structappend structdelete structupdate structcopy
    structclear
  )

  @impl true
  def names, do: @names

  @impl true
  def call("structkeyexists", [struct, key]) when is_map(struct),
    do: Struct.has_key?(struct, key(key))

  def call("structkeyexists", [_other, _key]), do: false

  def call("structnew", _args), do: %{}
  def call("structclear", [struct]) when is_map(struct), do: %{}
  def call("structcount", [struct]) when is_map(struct), do: map_size(struct)
  def call("structisempty", [struct]) when is_map(struct), do: map_size(struct) == 0
  def call("structkeyarray", [struct]) when is_map(struct), do: Struct.keys(struct)

  def call("structkeylist", [struct]) when is_map(struct),
    do: struct |> Struct.keys() |> Enum.join(",")

  # structInsert(struct, key, value [, allowOverwrite=false]): errors on an
  # existing key unless overwrite is allowed. Value-returning here.
  def call("structinsert", [struct, k, value]) when is_map(struct),
    do: insert(struct, k, value, false)

  def call("structinsert", [struct, k, value, overwrite]) when is_map(struct),
    do: insert(struct, k, value, Value.truthy?(overwrite))

  def call("structupdate", [struct, k, value]) when is_map(struct),
    do: Struct.put(struct, key(k), value)

  def call("structdelete", [struct, k]) when is_map(struct), do: Struct.delete(struct, key(k))
  def call("structcopy", [struct]) when is_map(struct), do: struct

  # structAppend(target, source [, overwrite=true]): merge source into target.
  def call("structappend", [target, source]) when is_map(target) and is_map(source),
    do: Struct.merge(target, source, true)

  def call("structappend", [target, source, overwrite]) when is_map(target) and is_map(source),
    do: Struct.merge(target, source, Value.truthy?(overwrite))

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  @spec insert(map(), any(), any(), boolean()) :: map()
  defp insert(struct, k, value, overwrite) do
    key = key(k)

    if not overwrite and Struct.has_key?(struct, key) do
      raise CFException, message: "Key [#{key}] already exists in struct"
    end

    Struct.put(struct, key, value)
  end

  @spec key(any()) :: String.t()
  defp key(k), do: Value.to_str(k)
end
