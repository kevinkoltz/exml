defmodule ExML.CFScript.Validator do
  @moduledoc """
  Build-time validation of `.cfc`/`.cfm` source: returns diagnostics so a host
  (e.g. a Mix compiler) can **fail the build on invalid code instead of letting
  it crash lazily at runtime**.

  Two diagnostic kinds:

    * `:syntax` — a member/statement that doesn't parse. Always an `:error`. Comes
      from `ExML.CFScript.Loader.diagnose/3` (whole-chunk parse failures that the
      lenient runtime path would silently drop) plus the parser's statement-level
      recovery markers (`{:unsupported, reason}`).
    * `:unsupported` — a CFML tag/attribute/construct exml doesn't implement yet
      (the `__exml_unsupported("…")` markers the converters emit). An `:error` by
      default, downgraded to `:warning` when allow-listed (see below).

  ## Allowing unsupported constructs

  During incremental porting a page may still use a not-yet-implemented tag.
  Downgrade specific unsupported constructs to warnings via:

    * `opts[:allow]` — a list of substrings matched against the diagnostic message
      (e.g. `["cfhttp", "cffile"]`), or
    * an inline directive in the source — `@exml-allow cfhttp, cffile` inside a
      `<!--- … --->` (`.cfm`) or `//` / `/* */` (`.cfc`) comment.

  Genuine runtime errors (undefined variables, dynamic includes, type mismatches)
  are *not* checked here — they surface at runtime.
  """

  alias ExML.CFScript.Loader

  @type diagnostic :: Loader.diagnostic()

  @doc "Validate `.cfc` source, returning all diagnostics (empty list = clean)."
  @spec validate_cfc(String.t(), String.t(), keyword()) :: [diagnostic()]
  def validate_cfc(source, file, opts \\ []) do
    allow = resolve_allow(source, opts)

    markers =
      source
      |> Loader.parse_source(file)
      |> scan(nil, [])
      |> Enum.map(&finalize(&1, file, allow))

    Loader.diagnose(source, file, :cfc) ++ Enum.reverse(markers)
  end

  @doc "Validate `.cfm` template source, returning all diagnostics."
  @spec validate_cfm(String.t(), String.t(), keyword()) :: [diagnostic()]
  def validate_cfm(source, file, opts \\ []) do
    allow = resolve_allow(source, opts)
    syntax = Loader.diagnose(source, file, :cfm)

    markers =
      case safe_parse_template(source, file) do
        {:ok, stmts} ->
          stmts |> scan(nil, []) |> Enum.map(&finalize(&1, file, allow)) |> Enum.reverse()

        :error ->
          []
      end

    syntax ++ markers
  end

  @spec safe_parse_template(String.t(), String.t()) :: {:ok, [tuple()]} | :error
  defp safe_parse_template(source, file) do
    {:ok, Loader.parse_template_source(source, file)}
  rescue
    _ -> :error
  end

  ## AST walk for unsupported / recovery markers

  # Generic structural walk: track the nearest enclosing `{:line, n, _}` and
  # collect `{:unsupported, reason}` recovery nodes and `__exml_unsupported("…")`
  # marker calls wherever they appear. Returns `{kind, line, message}` tuples.
  @spec scan(term(), pos_integer() | nil, [tuple()]) :: [tuple()]
  defp scan({:line, line, inner}, _line, acc), do: scan(inner, line, acc)

  defp scan({:unsupported, reason}, line, acc), do: [{:syntax, line, reason} | acc]

  defp scan({:call, {:var, name}, args} = node, line, acc) do
    acc =
      if String.downcase(name) == "__exml_unsupported",
        do: [{:unsupported, line, marker_message(args)} | acc],
        else: acc

    scan_children(node, line, acc)
  end

  defp scan(%_struct{} = struct, line, acc), do: scan(Map.from_struct(struct), line, acc)

  defp scan(map, line, acc) when is_map(map),
    do: Enum.reduce(Map.values(map), acc, &scan(&1, line, &2))

  defp scan(tuple, line, acc) when is_tuple(tuple), do: scan_children(tuple, line, acc)

  defp scan(list, line, acc) when is_list(list),
    do: Enum.reduce(list, acc, &scan(&1, line, &2))

  defp scan(_other, _line, acc), do: acc

  @spec scan_children(tuple(), pos_integer() | nil, [tuple()]) :: [tuple()]
  defp scan_children(tuple, line, acc) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &scan(&1, line, &2))
  end

  @spec marker_message([tuple()]) :: String.t()
  defp marker_message([{:lit, message} | _]), do: message
  defp marker_message(_), do: "unsupported CFML construct"

  ## Severity + allow-listing

  @spec finalize({:syntax | :unsupported, pos_integer() | nil, String.t()}, String.t(), [
          String.t()
        ]) ::
          diagnostic()
  defp finalize({:syntax, line, message}, file, _allow),
    do: %{severity: :error, kind: :syntax, file: file, line: line, message: message}

  defp finalize({:unsupported, line, message}, file, allow) do
    severity = if allowed?(message, allow), do: :warning, else: :error
    %{severity: severity, kind: :unsupported, file: file, line: line, message: message}
  end

  @spec allowed?(String.t(), [String.t()]) :: boolean()
  defp allowed?(message, allow) do
    down = String.downcase(message)
    Enum.any?(allow, &String.contains?(down, String.downcase(&1)))
  end

  # Merge `opts[:allow]` with any inline `@exml-allow a, b` directives in source.
  @spec resolve_allow(String.t(), keyword()) :: [String.t()]
  defp resolve_allow(source, opts) do
    Keyword.get(opts, :allow, []) ++ inline_allow(source)
  end

  @spec inline_allow(String.t()) :: [String.t()]
  defp inline_allow(source) do
    ~r/@exml-allow\s+([A-Za-z0-9_,\s]+)/i
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.flat_map(fn [list] -> String.split(list, ~r/[,\s]+/, trim: true) end)
  end
end
