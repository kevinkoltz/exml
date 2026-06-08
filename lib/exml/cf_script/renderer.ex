defmodule ExML.CFScript.Renderer do
  @moduledoc """
  Renders a `.cfm` template to output text.

  A template is parsed into a free-form statement body (see
  `ExML.CFScript.Loader.parse_template_source/2`) whose `writeOutput` calls and
  literal text accumulate in an `ExML.CFScript.OutputBuffer`. This module wires
  the buffer, the CFML scopes, and the optional executors into a `Context`, runs
  the body, and returns the accumulated iodata.

  ## Options

    * `:assigns` — a map seeded into the page `variables` scope (so `#name#`
      resolves). Phoenix assigns map here.
    * `:url` / `:form` / `:cgi` / `:request` / `:application` — maps seeded into
      the matching CFML scope. Unseeded scope reads crash loudly (no full null
      support), which is the intended "missing request lifecycle" behavior.
    * `:template_dir` — directory of the rendering file, for relative
      `<cfinclude>`/`<cfmodule>`. `:template_root` — the web root for absolute
      (`/…`) includes.
    * `:query_executor` — backs `<cfquery>` (see `ExML.CFScript.Runner`; `:stub`
      returns empty). `:http_executor` — backs `<cfhttp>`.
    * `:cfc_root` — root for `new cfc.x()` component resolution.
  """

  alias ExML.CFScript.{Context, Interpreter, Loader, OutputBuffer, Scope}

  @doc "Render `.cfm` template source, returning the output as iodata."
  @spec render_source(String.t(), keyword()) :: iodata()
  def render_source(source, opts \\ []) do
    label = Keyword.get(opts, :label, "<template>")

    source
    |> Loader.parse_template_source(label)
    |> render_ast(opts)
  end

  @doc "Render a pre-parsed template body (statement list), returning iodata."
  @spec render_ast([tuple()], keyword()) :: iodata()
  def render_ast(stmts, opts \\ []) do
    {:ok, buffer} = OutputBuffer.start_link()
    {:ok, cache} = Agent.start_link(fn -> %{} end)

    try do
      ctx = build_context(opts, buffer, cache)
      variables = Scope.new(stringify(Keyword.get(opts, :assigns, %{})))
      Interpreter.run_template(stmts, ctx, variables, Keyword.get(opts, :template_dir))
      OutputBuffer.to_iodata(buffer)
    after
      Agent.stop(cache)
      OutputBuffer.stop(buffer)
    end
  end

  ## Context assembly

  @spec build_context(keyword(), pid(), pid()) :: Context.t()
  defp build_context(opts, buffer, cache) do
    %Context{
      cfc_root: Keyword.get(opts, :cfc_root),
      cache: cache,
      natives: Keyword.get(opts, :natives, %{}),
      null_support: Keyword.get(opts, :null_support, false),
      query_executor: resolve_query_executor(Keyword.get(opts, :query_executor)),
      http_executor: Keyword.get(opts, :http_executor),
      output: buffer,
      template_root: Keyword.get(opts, :template_root),
      scopes: build_scopes(opts)
    }
  end

  # Seed each predefined CFML scope from a same-named option (a map), defaulting
  # to empty — mirrors `ExML.CFScript.Runner`'s scope seeding.
  @spec build_scopes(keyword()) :: %{optional(String.t()) => Scope.t()}
  defp build_scopes(opts) do
    Map.new(Interpreter.predefined_scopes(), fn name ->
      seed = opts |> Keyword.get(String.to_atom(name), %{}) |> stringify()
      {name, Scope.new(seed)}
    end)
  end

  @spec resolve_query_executor(any()) :: (String.t(), any() -> map()) | nil
  defp resolve_query_executor(:stub), do: fn _sql, _params -> %{columns: [], rows: []} end
  defp resolve_query_executor(other), do: other

  # Allow atom-keyed maps in options (e.g. Phoenix assigns) — CFML scopes key on
  # strings.
  @spec stringify(map()) :: map()
  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
