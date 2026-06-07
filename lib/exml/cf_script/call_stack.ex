defmodule ExML.CFScript.CallStack do
  @moduledoc """
  The CFML call stack for the spec currently running, used to give thrown
  exceptions a backtrace.

  Like the reporter and predefined scopes, this is process-local state (a spec
  runs synchronously in one process). The interpreter pushes a frame when it
  enters a user function and pops it on the way out; an exception snapshots the
  frames as it first crosses a frame boundary.
  """

  @key __MODULE__

  @type frame :: %{function: String.t(), source: String.t(), line: pos_integer() | nil}

  @doc "Clear the stack (call at the start of a run)."
  @spec reset() :: :ok
  def reset, do: put([])

  @doc "Push a frame as a function call is entered (`line` is its declaration line)."
  @spec push(String.t(), String.t(), pos_integer() | nil) :: :ok
  def push(function, source, line \\ nil) do
    put([%{function: function, source: source, line: line} | frames()])
  end

  @doc "Pop the innermost frame as a call returns."
  @spec pop() :: :ok
  def pop do
    case frames() do
      [_top | rest] -> put(rest)
      [] -> :ok
    end
  end

  @doc "Update the innermost frame's current line as execution advances."
  @spec set_line(pos_integer() | nil) :: :ok
  def set_line(line) do
    case frames() do
      [top | rest] -> put([%{top | line: line} | rest])
      [] -> :ok
    end
  end

  @doc "The current frames, innermost first."
  @spec frames() :: [frame()]
  def frames, do: Process.get(@key, [])

  @spec put([frame()]) :: :ok
  defp put(frames) do
    Process.put(@key, frames)
    :ok
  end
end
