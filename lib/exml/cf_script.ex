defmodule ExML.CFScript do
  @moduledoc """
  Public entry point for the cfscript interpreter.

  The interpreter parses and evaluates a subset of cfscript well enough to run
  a CFML codebase's test specs from Elixir. See `ExML.CFScript.Runner` for the spec
  runner and `ExML.CFScript.Parser` for the supported grammar.
  """

  alias ExML.CFScript.{Renderer, Runner, Validator}

  @doc """
  Run a CFML test spec file and return a summary map
  (`%{results:, passed:, failed:, total:}`).

  Requires the `:cfc_root` option pointing at the directory the `cfc.*` mapping
  resolves against.
  """
  @spec run_spec(String.t(), keyword()) :: Runner.summary()
  defdelegate run_spec(spec_path, opts), to: Runner, as: :run_spec_file

  @doc """
  Render a `.cfm` template string to output iodata. See `ExML.CFScript.Renderer`
  for options (`:assigns`, `:url`/`:form`, `:template_dir`/`:template_root`,
  `:query_executor`, ...).
  """
  @spec render_cfm(String.t(), keyword()) :: iodata()
  defdelegate render_cfm(source, opts \\ []), to: Renderer, as: :render_source

  @doc """
  Validate `.cfc` source ahead of time, returning build-time diagnostics
  (`%{severity:, kind:, file:, line:, message:}`). Empty list means clean. See
  `ExML.CFScript.Validator`.
  """
  @spec validate_cfc(String.t(), String.t(), keyword()) :: [Validator.diagnostic()]
  defdelegate validate_cfc(source, file, opts \\ []), to: Validator

  @doc "Validate `.cfm` template source ahead of time. See `ExML.CFScript.Validator`."
  @spec validate_cfm(String.t(), String.t(), keyword()) :: [Validator.diagnostic()]
  defdelegate validate_cfm(source, file, opts \\ []), to: Validator
end
