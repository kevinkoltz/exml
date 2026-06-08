defmodule ExML.CFScript.OutputBuffer do
  @moduledoc """
  The page-output accumulator for `.cfm` template rendering.

  An Agent holding a reversed iolist of emitted chunks plus an optional
  content-type (set by `cfcontent`). `writeOutput`, literal template text, and
  `<cfoutput>` bodies append here; the renderer collects `to_iodata/1` at the
  end. One buffer is shared across a page and everything it `<cfinclude>`s /
  `<cfmodule>`s, so output interleaves in evaluation order.
  """

  use Agent

  @type t :: pid()

  @doc "Start an empty buffer."
  @spec start_link() :: {:ok, t()}
  def start_link, do: Agent.start_link(fn -> %{io: [], content_type: nil} end)

  @doc "Append a chunk (any iodata) to the buffer."
  @spec append(t(), iodata()) :: :ok
  def append(pid, chunk), do: Agent.update(pid, fn s -> %{s | io: [chunk | s.io]} end)

  @doc "Discard everything emitted so far (`cfcontent reset=true`)."
  @spec reset(t()) :: :ok
  def reset(pid), do: Agent.update(pid, fn s -> %{s | io: []} end)

  @doc "Record the response content-type (`cfcontent type=...`)."
  @spec put_content_type(t(), String.t()) :: :ok
  def put_content_type(pid, type), do: Agent.update(pid, &%{&1 | content_type: type})

  @doc "The accumulated output, in emission order, as iodata."
  @spec to_iodata(t()) :: iodata()
  def to_iodata(pid), do: Agent.get(pid, fn s -> Enum.reverse(s.io) end)

  @doc "The recorded content-type, or nil."
  @spec content_type(t()) :: String.t() | nil
  def content_type(pid), do: Agent.get(pid, & &1.content_type)

  @doc "Stop the buffer process."
  @spec stop(t()) :: :ok
  def stop(pid), do: Agent.stop(pid)
end
