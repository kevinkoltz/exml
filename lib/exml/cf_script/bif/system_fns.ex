defmodule ExML.CFScript.BIF.SystemFns do
  @moduledoc """
  Output / debugging built-ins (`writeOutput`, `writeDump`/`dump`).

  The interpreter has no page-output buffer, so these are no-ops that return
  `""` — a function that concatenates the result still works, and `<cfdump>`
  (which the tag converter rewrites to `writeDump`-style calls or strips)
  doesn't take down the function.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.CFException

  @names ~w(writeoutput writedump dump)

  @impl true
  def names, do: @names

  # writeOutput(text) would write to the page buffer; here it's a no-op.
  @impl true
  def call("writeoutput", [_value | _]), do: ""
  def call("writeoutput", []), do: ""

  # writeDump/dump are debug output — no-ops (named args like var=/label= are
  # dropped before reaching a BIF, so any arity is accepted).
  def call(name, _args) when name in ["writedump", "dump"], do: ""

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end
end
