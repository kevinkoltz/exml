defmodule ExML.CFScript.BIF.ConversionFns do
  @moduledoc """
  CFML value-conversion built-in functions (`javaCast`, ...).

  `javaCast` is mainly used to produce a null (`javaCast("null", "")`)
  and to coerce simple types for Java interop; the type cases we see are
  handled, others pass the value through.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @names ~w(javacast)

  @impl true
  def names, do: @names

  @impl true
  def call("javacast", [type, value]) do
    case String.downcase(Value.to_str(type)) do
      "null" -> nil
      t when t in ["int", "long", "short", "byte", "biginteger"] -> trunc(Value.to_number(value))
      t when t in ["double", "float", "bigdecimal"] -> Value.to_number(value) / 1
      "string" -> Value.to_str(value)
      "boolean" -> Value.truthy?(value)
      _ -> value
    end
  end

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end
end
