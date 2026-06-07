defmodule ExML.CFScript.NativeObject do
  @moduledoc """
  A host object exposed to cfscript: a value whose methods are backed by Elixir
  functions. `obj.method(args)` dispatches to `dispatch.(name, args)`.

  This lets the host inject objects the interpreter can't construct in CFML —
  e.g. a `request.logger` backed by Elixir's `Logger`. A dispatch returning the
  `:__self__` sentinel makes the interpreter return the object itself (so
  builder-style chaining like `logger.build(ctx).info(msg)` works).
  """

  require Logger

  alias ExML.CFScript.Value

  @type t :: %__MODULE__{label: String.t(), dispatch: (String.t(), [any()] -> any())}
  defstruct [:label, :dispatch]

  @doc "Build a host object from a `(method_name, args) -> result` dispatch function."
  @spec new(String.t(), (String.t(), [any()] -> any())) :: t()
  def new(label, dispatch) when is_function(dispatch, 2) do
    %__MODULE__{label: label, dispatch: dispatch}
  end

  @doc "Invoke a method on the host object."
  @spec invoke(t(), String.t(), [any()]) :: any()
  def invoke(%__MODULE__{dispatch: dispatch}, name, args), do: dispatch.(name, args)

  @doc """
  A logger object backed by Elixir's `Logger`: `info`/`debug`/`warn`(`warning`)/
  `error` log their first argument at the matching level (the host controls
  level filtering). Any other method (e.g. `build`) is a chainable no-op.
  """
  @spec logger() :: t()
  def logger do
    new("logger", fn name, args -> log_dispatch(String.downcase(name), args) end)
  end

  @spec log_dispatch(String.t(), [any()]) :: nil | :__self__
  defp log_dispatch(name, args) do
    case level_for(name) do
      nil ->
        :__self__

      level ->
        Logger.log(level, message_text(args))
        nil
    end
  end

  @spec level_for(String.t()) :: Logger.level() | nil
  defp level_for("info"), do: :info
  defp level_for("debug"), do: :debug
  defp level_for("warn"), do: :warning
  defp level_for("warning"), do: :warning
  defp level_for("error"), do: :error
  defp level_for(_name), do: nil

  @spec message_text([any()]) :: String.t()
  defp message_text([]), do: ""
  defp message_text([msg | _]), do: Value.display(msg)
end

defimpl ExML.CFScript.CFValue, for: ExML.CFScript.NativeObject do
  def to_str(obj),
    do: raise(ExML.CFScript.CFException, message: "Can't cast [#{obj.label}] to String")

  def as_number(_obj), do: :error
  def truthy?(_obj), do: true
  def type_name(_obj), do: :object
end
