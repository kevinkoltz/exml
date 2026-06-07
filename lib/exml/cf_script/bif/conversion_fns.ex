defmodule ExML.CFScript.BIF.ConversionFns do
  @moduledoc """
  CFML value-conversion built-in functions (`javaCast`, ...).

  `javaCast` is mainly used to produce a null (`javaCast("null", "")`)
  and to coerce simple types for Java interop; the type cases we see are
  handled, others pass the value through.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @names ~w(javacast int fix tostring abs round ceiling floor)

  @impl true
  def names, do: @names

  # Int: integer part, truncated toward zero (Lucee Int()).
  @impl true
  def call("int", [v]), do: trunc(Value.to_number(v))
  def call("fix", [v]), do: trunc(Value.to_number(v))
  def call("abs", [v]), do: abs(Value.to_number(v))
  def call("round", [v]), do: round(Value.to_number(v))
  def call("ceiling", [v]), do: v |> to_float() |> Float.ceil() |> trunc()
  def call("floor", [v]), do: v |> to_float() |> Float.floor() |> trunc()
  def call("tostring", [v]), do: Value.to_str(v)
  def call("tostring", [v, _encoding]), do: Value.to_str(v)

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

  @spec to_float(any()) :: float()
  defp to_float(v), do: Value.to_number(v) * 1.0
end
