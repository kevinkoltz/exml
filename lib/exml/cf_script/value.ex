defmodule ExML.CFScript.Value do
  @moduledoc """
  Runtime value structs and the binary value operations CFML needs.

  Per-type coercion (string / number / boolean / type label) lives in the
  `ExML.CFScript.CFValue` protocol; this module is the facade for it plus the
  operations that take *two* values — equality and ordering — which a
  single-dispatch protocol can't express directly.
  """

  alias ExML.CFScript.{CFValue, Heap}

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

  defmodule ArrayRef do
    @moduledoc "A mutable reference to a CFML array (backed by `ExML.CFScript.Heap`)."
    @type t :: %__MODULE__{cell: reference()}
    defstruct [:cell]
  end

  defmodule StructRef do
    @moduledoc "A mutable reference to a CFML struct (backed by `ExML.CFScript.Heap`)."
    @type t :: %__MODULE__{cell: reference()}
    defstruct [:cell]
  end

  ## Single-value coercion (delegated to the protocol)

  @doc "Coerce a value to a CFML string."
  @spec to_str(any()) :: String.t()
  defdelegate to_str(value), to: CFValue

  @doc "CFML truthiness."
  @spec truthy?(any()) :: boolean()
  defdelegate truthy?(value), to: CFValue

  @doc "Attempt to interpret a value as a number."
  @spec as_number(any()) :: {:ok, number()} | :error
  defdelegate as_number(value), to: CFValue

  @doc "CFML type label for a value."
  @spec type_name(any()) :: atom()
  defdelegate type_name(value), to: CFValue

  @doc "Coerce to a number, raising a CFML cast error if not numeric."
  @spec to_number(any()) :: number()
  def to_number(value) do
    case as_number(value) do
      {:ok, n} ->
        n

      :error ->
        raise ExML.CFScript.CFException, message: "Can't cast [#{display(value)}] to a number"
    end
  end

  @doc "Whether a value is a CFML \"simple\" value (string / number / boolean)."
  @spec simple?(any()) :: boolean()
  def simple?(value), do: type_name(value) in [:string, :number, :boolean]

  ## Binary operations

  @doc """
  CFML loose equality (`==`/`eq`): numeric comparison when both operands look
  numeric, otherwise a case-insensitive string comparison.
  """
  @spec equals?(any(), any()) :: boolean()
  def equals?(a, b), do: deref_equals?(Heap.deref(a), Heap.deref(b))

  # Arrays/structs compare structurally (Lucee throws on complex `==`, but
  # structural equality is more useful for assertions); simple values compare
  # numerically when both look numeric, else case-insensitively.
  @spec deref_equals?(any(), any()) :: boolean()
  defp deref_equals?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and a |> Enum.zip(b) |> Enum.all?(fn {x, y} -> equals?(x, y) end)
  end

  defp deref_equals?(a, b)
       when is_map(a) and is_map(b) and not is_struct(a) and not is_struct(b) do
    Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort() and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and equals?(v, Map.fetch!(b, k)) end)
  end

  defp deref_equals?(a, b) do
    case {as_number(a), as_number(b)} do
      {{:ok, na}, {:ok, nb}} -> na == nb
      _ -> String.downcase(to_str(a)) == String.downcase(to_str(b))
    end
  end

  @doc "Ordering comparison returning `:lt | :eq | :gt`, used by `<`, `>`, `<=`, `>=`."
  @spec compare(any(), any()) :: :lt | :eq | :gt
  def compare(a, b) do
    case {as_number(a), as_number(b)} do
      {{:ok, na}, {:ok, nb}} -> number_compare(na, nb)
      _ -> string_compare(to_str(a), to_str(b))
    end
  end

  @spec number_compare(number(), number()) :: :lt | :eq | :gt
  defp number_compare(a, b) when a < b, do: :lt
  defp number_compare(a, b) when a > b, do: :gt
  defp number_compare(_a, _b), do: :eq

  @spec string_compare(String.t(), String.t()) :: :lt | :eq | :gt
  defp string_compare(a, b) do
    a = String.downcase(a)
    b = String.downcase(b)

    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  ## Human-facing display (never raises — for assertion/error messages)

  @doc """
  A safe, human-readable rendering for messages. Unlike `to_str/1` this never
  raises on complex values; it labels them instead.
  """
  @spec display(any()) :: String.t()
  def display(value) do
    case type_name(value) do
      t when t in [:string, :number, :boolean] -> to_str(value)
      :null -> ""
      :array -> "[array (#{length(Heap.deref(value))})]"
      :struct -> "[struct (#{map_size(Heap.deref(value))} keys)]"
      :component -> "[component #{component_path(value)}]"
      other -> "[#{other}]"
    end
  end

  defp component_path(%Instance{type_path: path}), do: path
  defp component_path(%ComponentType{path: path}), do: path
  defp component_path(_), do: ""
end
