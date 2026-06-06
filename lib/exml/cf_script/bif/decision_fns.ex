defmodule ExML.CFScript.BIF.DecisionFns do
  @moduledoc """
  CFML decision / type-predicate built-in functions (the `is*` family), ported
  from Lucee 6.2.5 `lucee.runtime.op.Decision`.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  # Lucee isNumber grammar: optional sign, digits with at most one dot, optional
  # single exponent. No date fallback (that path is reserved for casting, not
  # the isNumeric predicate).
  @numeric_regex ~r/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/

  @names ~w(isnull issimplevalue isnumeric isboolean isarray isstruct isempty isdefined isobject isquery)

  @impl true
  def names, do: @names

  @impl true
  def call("isnull", [v]), do: is_nil(v)

  # isSimpleValue: string / number / boolean / date (dates not modelled yet).
  def call("issimplevalue", [v]), do: Value.simple?(v)

  # isNumeric: real numbers, or strings matching the numeric grammar. Booleans
  # are NOT numeric in Lucee.
  def call("isnumeric", [v]) when is_number(v), do: true
  def call("isnumeric", [v]) when is_binary(v), do: Regex.match?(@numeric_regex, String.trim(v))
  def call("isnumeric", [_v]), do: false

  # isBoolean: a boolean, or a string that is exactly true/false/yes/no
  # (length >= 2, case-insensitive, no trim). Numbers are NOT boolean.
  def call("isboolean", [v]) when is_boolean(v), do: true
  def call("isboolean", [v]) when is_binary(v), do: boolean_word?(v)
  def call("isboolean", [_v]), do: false

  # Plain Elixir maps are CFML structs; the interpreter's component structs are
  # not (is_struct/1 is true for them).
  def call("isarray", [v]), do: is_list(v)
  def call("isstruct", [v]), do: is_map(v) and not is_struct(v)

  def call("isobject", [v]), do: match?(%ExML.CFScript.Value.Instance{}, v)
  def call("isquery", [_v]), do: false

  # isEmpty: empty string / array / struct.
  def call("isempty", [v]) when is_binary(v), do: v == ""
  def call("isempty", [v]) when is_list(v), do: v == []
  def call("isempty", [v]) when is_map(v) and not is_struct(v), do: map_size(v) == 0
  def call("isempty", [_v]), do: false

  # isDefined takes a variable-path string; scope resolution happens in the
  # interpreter, so a value reaching here is defined unless it is null.
  def call("isdefined", [v]), do: not is_nil(v)

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  @spec boolean_word?(String.t()) :: boolean()
  defp boolean_word?(str) do
    byte_size(str) >= 2 and String.downcase(str) in ["true", "false", "yes", "no"]
  end
end
