defmodule ExML.CFScript.Value do
  @moduledoc """
  Runtime value types and CFML value semantics (coercion, truthiness, equality).

  Runtime values are: Elixir binaries (strings), integers/floats (numbers),
  booleans, `nil` (CFML null), plus the structs defined here for components,
  closures, and native functions.
  """

  defmodule Instance do
    @moduledoc "An instantiated CFC."
    @type t :: %__MODULE__{type_path: String.t(), component: struct(), variables: reference()}
    defstruct [:type_path, :component, :variables]
  end

  defmodule ComponentType do
    @moduledoc "A reference to a component definition (target of `::` and `new`)."
    @type t :: %__MODULE__{path: String.t(), component: struct()}
    defstruct [:path, :component]
  end

  defmodule Namespace do
    @moduledoc "A component mapping namespace, e.g. the `cfc` in `cfc.value`."
    @type t :: %__MODULE__{base: String.t()}
    defstruct [:base]
  end

  defmodule Closure do
    @moduledoc "An anonymous `function(...) {...}` plus its captured environment."
    @type t :: %__MODULE__{params: list(), body: list(), env: term()}
    defstruct [:params, :body, :env]
  end

  defmodule Native do
    @moduledoc "A host (Elixir) function exposed to cfscript. `fun` takes (args, env)."
    @type t :: %__MODULE__{name: String.t(), fun: (list(), term() -> any())}
    defstruct [:name, :fun]
  end

  @doc "CFML truthiness."
  @spec truthy?(any()) :: boolean()
  def truthy?(true), do: true
  def truthy?(false), do: false
  def truthy?(nil), do: false
  def truthy?(n) when is_number(n), do: n != 0

  def truthy?(s) when is_binary(s) do
    case String.downcase(String.trim(s)) do
      "true" -> true
      "yes" -> true
      "false" -> false
      "no" -> false
      "" -> false
      other -> numeric_truthy(other)
    end
  end

  def truthy?(_), do: true

  @spec numeric_truthy(String.t()) :: boolean()
  defp numeric_truthy(s) do
    case parse_number(s) do
      {:ok, n} -> n != 0
      :error -> raise ExML.CFScript.CFException, message: "Cannot cast '#{s}' to a boolean"
    end
  end

  @doc "Stringify a value for concatenation / output, CFML-style."
  @spec to_str(any()) :: String.t()
  def to_str(nil), do: ""
  def to_str(s) when is_binary(s), do: s
  def to_str(true), do: "true"
  def to_str(false), do: "false"
  def to_str(n) when is_integer(n), do: Integer.to_string(n)

  def to_str(n) when is_float(n) do
    # CFML prints whole floats without a trailing ".0".
    if n == Float.round(n) and abs(n) < 1.0e15 do
      n |> trunc() |> Integer.to_string()
    else
      Float.to_string(n)
    end
  end

  def to_str(%Instance{type_path: p}), do: "[component #{p}]"
  def to_str(other), do: inspect(other)

  @doc """
  CFML loose equality (`==`/`eq`): numeric comparison when both operands look
  numeric, otherwise a case-insensitive string comparison.
  """
  @spec equals?(any(), any()) :: boolean()
  def equals?(a, b) do
    case {as_number(a), as_number(b)} do
      {{:ok, na}, {:ok, nb}} -> na == nb
      _ -> String.downcase(to_str(a)) == String.downcase(to_str(b))
    end
  end

  @doc "Numeric comparison helper returning :lt | :eq | :gt for `<`,`>`,`<=`,`>=`."
  @spec compare(any(), any()) :: :lt | :eq | :gt
  def compare(a, b) do
    case {as_number(a), as_number(b)} do
      {{:ok, na}, {:ok, nb}} -> num_compare(na, nb)
      _ -> string_compare(a, b)
    end
  end

  defp num_compare(a, b) when a < b, do: :lt
  defp num_compare(a, b) when a > b, do: :gt
  defp num_compare(_, _), do: :eq

  defp string_compare(a, b) do
    sa = String.downcase(to_str(a))
    sb = String.downcase(to_str(b))

    cond do
      sa < sb -> :lt
      sa > sb -> :gt
      true -> :eq
    end
  end

  @doc "Coerce to a number, raising if not numeric."
  @spec to_number(any()) :: number()
  def to_number(value) do
    case as_number(value) do
      {:ok, n} -> n
      :error -> raise ExML.CFScript.CFException, message: "Cannot cast '#{to_str(value)}' to a number"
    end
  end

  @doc "Attempt to interpret a value as a number."
  @spec as_number(any()) :: {:ok, number()} | :error
  def as_number(n) when is_number(n), do: {:ok, n}
  def as_number(true), do: {:ok, 1}
  def as_number(false), do: {:ok, 0}
  def as_number(s) when is_binary(s), do: parse_number(String.trim(s))
  def as_number(_), do: :error

  @spec parse_number(String.t()) :: {:ok, number()} | :error
  defp parse_number(s) do
    case Integer.parse(s) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(s) do
          {f, ""} -> {:ok, f}
          _ -> :error
        end
    end
  end

  @doc "Whether a value is a CFML \"simple\" value (string/number/boolean/date)."
  @spec simple?(any()) :: boolean()
  def simple?(v) when is_binary(v) or is_number(v) or is_boolean(v), do: true
  def simple?(_), do: false
end
