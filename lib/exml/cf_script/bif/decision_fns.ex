defmodule ExML.CFScript.BIF.DecisionFns do
  @moduledoc """
  CFML decision / type-predicate built-in functions (the `is*` family),
  matching Lucee 6.2 semantics.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @names ~w(isnull issimplevalue isnumeric isboolean isarray isstruct isempty isdefined)

  @impl true
  def names, do: @names

  @impl true
  def call("isnull", [v]), do: is_nil(v)
  def call("issimplevalue", [v]), do: Value.simple?(v)
  def call("isnumeric", [v]), do: Value.as_number(v) != :error
  def call("isarray", [v]), do: is_list(v)
  def call("isstruct", [v]), do: is_map(v) and not is_struct(v)

  def call("isboolean", [v]) do
    case v do
      b when is_boolean(b) -> true
      n when is_number(n) -> true
      s when is_binary(s) -> String.downcase(String.trim(s)) in ["true", "false", "yes", "no"]
      _ -> false
    end
  end

  # isEmpty: true for empty string, empty array, or empty struct.
  def call("isempty", [v]) when is_binary(v), do: v == ""
  def call("isempty", [v]) when is_list(v), do: v == []
  def call("isempty", [v]) when is_map(v), do: map_size(v) == 0
  def call("isempty", [_v]), do: false

  # isDefined takes a string variable path; the interpreter resolves scope
  # membership elsewhere, so a bare value reaching here is treated as defined.
  def call("isdefined", [v]), do: not is_nil(v)

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end
end
