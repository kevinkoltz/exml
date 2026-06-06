defmodule ExML.CFScript.Reporter do
  @moduledoc """
  Collects test results emitted by the native `describe`/`it`/`assert_*`
  functions during a spec run.

  Like the scopes, this is process-local state held in the process dictionary —
  a spec runs synchronously in one process, so there is no cross-process
  contention.
  """

  @type status :: :pass | :fail | :error
  @type result :: %{status: status(), group: String.t(), description: String.t(), message: String.t() | nil}

  @doc "Begin a fresh collection."
  @spec start() :: :ok
  def start do
    Process.put(__MODULE__, %{results: [], groups: []})
    :ok
  end

  @doc "Enter a `describe` group."
  @spec push_group(String.t()) :: :ok
  def push_group(name) do
    update(fn s -> %{s | groups: s.groups ++ [name]} end)
  end

  @doc "Leave the current `describe` group."
  @spec pop_group() :: :ok
  def pop_group do
    update(fn s -> %{s | groups: Enum.drop(s.groups, -1)} end)
  end

  @doc "Record a result for the current group."
  @spec record(status(), String.t(), String.t() | nil) :: :ok
  def record(status, description, message \\ nil) do
    update(fn s ->
      result = %{
        status: status,
        group: Enum.join(s.groups, " › "),
        description: description,
        message: message
      }

      %{s | results: [result | s.results]}
    end)
  end

  @doc "All results in the order they were recorded."
  @spec results() :: [result()]
  def results, do: state().results |> Enum.reverse()

  @spec state() :: map()
  defp state, do: Process.get(__MODULE__, %{results: [], groups: []})

  @spec update((map() -> map())) :: :ok
  defp update(fun) do
    Process.put(__MODULE__, fun.(state()))
    :ok
  end
end
