defmodule ExML.CFScript do
  @moduledoc """
  Public entry point for the cfscript interpreter.

  The interpreter parses and evaluates a subset of cfscript well enough to run
  a CFML codebase's test specs from Elixir. See `ExML.CFScript.Runner` for the spec
  runner and `ExML.CFScript.Parser` for the supported grammar.
  """

  alias ExML.CFScript.Runner

  @doc """
  Run a CFML test spec file and return a summary map
  (`%{results:, passed:, failed:, total:}`).

  Requires the `:cfc_root` option pointing at the directory the `cfc.*` mapping
  resolves against.
  """
  @spec run_spec(String.t(), keyword()) :: Runner.summary()
  defdelegate run_spec(spec_path, opts), to: Runner, as: :run_spec_file
end
