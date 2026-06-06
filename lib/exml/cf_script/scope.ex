defmodule ExML.CFScript.Scope do
  @moduledoc """
  A mutable, case-insensitive variable scope.

  CFML scopes (`variables`, `local`, `arguments`) are mutable and shared — a
  closure created inside a function sees later writes to the enclosing
  `variables` scope. Modelling that with immutable Elixir maps threaded through
  every call would be unwieldy, especially across the native `describe`/`it`
  callbacks. Since the interpreter runs synchronously in a single process, we
  back each scope with the process dictionary keyed by a unique reference.

  Keys are stored downcased to honor CFML's case-insensitive variable and
  struct-key semantics.
  """

  @opaque t :: reference()

  @doc "Create a new empty scope, optionally seeded from a map of initial values."
  @spec new(map()) :: t()
  def new(initial \\ %{}) do
    ref = make_ref()
    contents = for {k, v} <- initial, into: %{}, do: {downcase(k), v}
    Process.put({__MODULE__, ref}, contents)
    ref
  end

  @doc "Whether `key` is present in the scope (case-insensitive)."
  @spec has?(t(), String.t()) :: boolean()
  def has?(ref, key), do: Map.has_key?(contents(ref), downcase(key))

  @doc "Fetch `key`, returning `{:ok, value}` or `:error`."
  @spec fetch(t(), String.t()) :: {:ok, any()} | :error
  def fetch(ref, key), do: Map.fetch(contents(ref), downcase(key))

  @doc "Put `key` => `value`, returning the scope ref for chaining."
  @spec put(t(), String.t(), any()) :: t()
  def put(ref, key, value) do
    Process.put({__MODULE__, ref}, Map.put(contents(ref), downcase(key), value))
    ref
  end

  @doc "Return the scope contents as a plain map (downcased keys)."
  @spec to_map(t()) :: map()
  def to_map(ref), do: contents(ref)

  @spec contents(t()) :: map()
  defp contents(ref), do: Process.get({__MODULE__, ref}, %{})

  @spec downcase(String.t() | atom()) :: String.t()
  defp downcase(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp downcase(key) when is_binary(key), do: String.downcase(key)
end
