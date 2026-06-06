defmodule ExML.CFScript.BIF.StructFns do
  @moduledoc """
  CFML struct built-in functions. Structs are modelled as Elixir maps with
  downcased string keys (CFML struct keys are case-insensitive).
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @names ~w(structkeyexists structnew structcount structisempty structkeyarray structkeylist)

  @impl true
  def names, do: @names

  @impl true
  def call("structkeyexists", [struct, key]) when is_map(struct) do
    Map.has_key?(struct, key(key))
  end

  def call("structkeyexists", [_other, _key]), do: false

  def call("structnew", _args), do: %{}
  def call("structcount", [struct]) when is_map(struct), do: map_size(struct)
  def call("structisempty", [struct]) when is_map(struct), do: map_size(struct) == 0
  def call("structkeyarray", [struct]) when is_map(struct), do: Map.keys(struct)
  def call("structkeylist", [struct]) when is_map(struct), do: struct |> Map.keys() |> Enum.join(",")

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  @spec key(any()) :: String.t()
  defp key(k), do: String.downcase(Value.to_str(k))
end
