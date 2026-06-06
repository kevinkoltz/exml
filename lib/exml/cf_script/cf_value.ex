defprotocol ExML.CFScript.CFValue do
  @moduledoc """
  CFML value semantics as a protocol — single-dispatch, pure per-type
  transformation, which is exactly the case the hapi guides reserve protocols
  for (vs. behaviours for swappable providers, vs. plain function heads for a
  small closed set).

  Each runtime value type (string, number, boolean, null, struct, array, and
  the interpreter's own component/closure structs) implements how it coerces to
  a CFML string, to a number, and to a boolean, and what CFML type label it
  reports. Binary operations that need two values (`==`, `<`) live in
  `ExML.CFScript.Value` and are built on top of this protocol.
  """

  @fallback_to_any false

  @doc "Coerce to a CFML string (raises for complex types, as Lucee does)."
  @spec to_str(t()) :: String.t()
  def to_str(value)

  @doc "Attempt to interpret as a number: `{:ok, number}` or `:error`."
  @spec as_number(t()) :: {:ok, number()} | :error
  def as_number(value)

  @doc "CFML truthiness."
  @spec truthy?(t()) :: boolean()
  def truthy?(value)

  @doc "CFML type label, e.g. `:string`, `:number`, `:struct`, `:component`."
  @spec type_name(t()) :: atom()
  def type_name(value)
end

defmodule ExML.CFScript.CFValue.Number do
  @moduledoc false
  # Shared coercion logic for the Integer and Float protocol implementations.

  @spec to_str(number()) :: String.t()
  def to_str(n) when is_integer(n), do: Integer.to_string(n)

  def to_str(n) when is_float(n) do
    # Lucee prints whole floats without a trailing ".0" (e.g. 1.0 -> "1").
    if n == Float.round(n) and abs(n) < 1.0e15 do
      n |> trunc() |> Integer.to_string()
    else
      Float.to_string(n)
    end
  end
end

defimpl ExML.CFScript.CFValue, for: Integer do
  alias ExML.CFScript.CFValue

  def to_str(n), do: CFValue.Number.to_str(n)
  def as_number(n), do: {:ok, n}
  def truthy?(n), do: n != 0
  def type_name(_n), do: :number
end

defimpl ExML.CFScript.CFValue, for: Float do
  alias ExML.CFScript.CFValue

  def to_str(n), do: CFValue.Number.to_str(n)
  def as_number(n), do: {:ok, n}
  def truthy?(n), do: n != 0
  def type_name(_n), do: :number
end

defimpl ExML.CFScript.CFValue, for: BitString do
  def to_str(s), do: s

  def as_number(s) do
    trimmed = String.trim(s)

    case Integer.parse(trimmed) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(trimmed) do
          {f, ""} -> {:ok, f}
          _ -> :error
        end
    end
  end

  def truthy?(s) do
    case String.downcase(String.trim(s)) do
      v when v in ["true", "yes"] -> true
      v when v in ["false", "no", ""] -> false
      _ -> numeric_truthy(s)
    end
  end

  defp numeric_truthy(s) do
    case as_number(s) do
      {:ok, n} -> n != 0
      :error -> raise ExML.CFScript.CFException, message: "Can't cast String [#{s}] to a boolean value"
    end
  end

  def type_name(_s), do: :string
end

defimpl ExML.CFScript.CFValue, for: Atom do
  # CFML null is modelled as Elixir nil; CFML booleans as true/false.
  def to_str(nil), do: ""
  def to_str(true), do: "true"
  def to_str(false), do: "false"

  def as_number(true), do: {:ok, 1}
  def as_number(false), do: {:ok, 0}
  def as_number(nil), do: :error

  def truthy?(true), do: true
  def truthy?(false), do: false
  def truthy?(nil), do: false

  def type_name(nil), do: :null
  def type_name(b) when is_boolean(b), do: :boolean
end

defimpl ExML.CFScript.CFValue, for: Map do
  # A plain map is a CFML struct. Lucee throws when coercing it to a string.
  def to_str(_struct), do: raise(ExML.CFScript.CFException, message: "Can't cast Complex Object Type Struct to String")
  def as_number(_struct), do: :error
  def truthy?(_struct), do: true
  def type_name(_struct), do: :struct
end

defimpl ExML.CFScript.CFValue, for: List do
  # A list is a CFML array. Lucee throws when coercing it to a string.
  def to_str(_array), do: raise(ExML.CFScript.CFException, message: "Can't cast Complex Object Type Array to String")
  def as_number(_array), do: :error
  def truthy?(_array), do: true
  def type_name(_array), do: :array
end

# The interpreter's own runtime structs. None coerce to a string/number; they
# differ only in the CFML type label they report, so they are grouped by label.
defimpl ExML.CFScript.CFValue,
  for: [ExML.CFScript.Value.Instance, ExML.CFScript.Value.ComponentType] do
  def to_str(value), do: raise(ExML.CFScript.CFException, message: "Can't cast #{inspect(value.__struct__)} to String")
  def as_number(_value), do: :error
  def truthy?(_value), do: true
  def type_name(_value), do: :component
end

defimpl ExML.CFScript.CFValue, for: ExML.CFScript.Value.Namespace do
  def to_str(value), do: raise(ExML.CFScript.CFException, message: "Can't cast #{inspect(value.__struct__)} to String")
  def as_number(_value), do: :error
  def truthy?(_value), do: true
  def type_name(_value), do: :namespace
end

defimpl ExML.CFScript.CFValue,
  for: [ExML.CFScript.Value.Closure, ExML.CFScript.Value.Native] do
  def to_str(value), do: raise(ExML.CFScript.CFException, message: "Can't cast #{inspect(value.__struct__)} to String")
  def as_number(_value), do: :error
  def truthy?(_value), do: true
  def type_name(_value), do: :function
end
