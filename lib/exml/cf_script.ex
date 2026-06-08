defmodule ExML.CFScript do
  @moduledoc """
  Public entry point for the cfscript interpreter.

  The interpreter parses and evaluates a subset of cfscript well enough to run
  a CFML codebase's test specs from Elixir. See `ExML.CFScript.Runner` for the spec
  runner and `ExML.CFScript.Parser` for the supported grammar.
  """

  alias ExML.CFScript.{Loader, Renderer, Runner, Validator}

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
  Parse `.cfm` template source into its statement AST (a plain term, safe to
  `Macro.escape/1`) for **ahead-of-time** compilation: a host template engine
  parses at build time (raising — a compile error — on bad syntax) and embeds the
  result, then renders it per request with `render_cfm_ast/2`. Raises on a parse
  error.
  """
  @spec compile_cfm(String.t(), String.t()) :: [tuple()]
  defdelegate compile_cfm(source, file), to: Loader, as: :parse_template_source

  @doc """
  Render a pre-parsed `.cfm` AST (from `compile_cfm/2`) to output iodata. Same
  options as `render_cfm/2`.
  """
  @spec render_cfm_ast([tuple()], keyword()) :: iodata()
  defdelegate render_cfm_ast(ast, opts \\ []), to: Renderer, as: :render_ast

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
