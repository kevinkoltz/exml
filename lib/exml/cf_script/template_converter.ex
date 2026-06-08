defmodule ExML.CFScript.TemplateConverter do
  @moduledoc """
  Converts a `.cfm` *template* (mixed HTML + CFML) into a cfscript body that
  emits its output via `writeOutput(...)`, so the existing lexer/parser/
  interpreter can run it with an `ExML.CFScript.OutputBuffer`.

  Unlike `ExML.CFScript.TagConverter` (which targets `.cfc` function bodies and
  *discards* literal text and `<cfoutput>`), this preserves the page's text:

    * Literal text outside `<cfoutput>` → `writeOutput("…")` with `#` escaped to
      `##` (no interpolation), so HTML like `id="#nav"` stays literal.
    * `<cfoutput>…</cfoutput>` → its body is emitted with `#expr#` interpolation
      live (the parser's string interpolation handles it).
    * `<cfscript>…</cfscript>` → inlined verbatim (already cfscript).
    * `<cfinclude template="…">` / `<cfmodule template="…" …>` → runtime
      `__exml_include(…)` / `__exml_module(…, {…})` calls.
    * `<cfloop query="q">` / `<cfoutput query="q">` → a row loop
      `for (q in __exml_rows(q)) { … }` (scoped `#q.col#` access).
    * Every other CFML statement/control tag (`<cfif>`, `<cfloop>`, `<cfset>`,
      `<cfparam>`, `<cfswitch>`, `<cfquery>`, …) is converted by delegating the
      single tag to `TagConverter.convert_body/1`, reusing all of its logic. An
      unsupported tag becomes a loud `__exml_unsupported(…)` marker.

  Text and converted tags keep their original newline count, so error line
  numbers map back to the `.cfm` reasonably well.
  """

  alias ExML.CFScript.TagConverter

  # Quote-aware tag inner-content (a `>` inside a quoted attribute value doesn't
  # close the tag) — same approach as TagConverter.
  @tag_content ~S{(?:[^>"']|"(?:""|[^"])*"|'(?:''|[^'])*')*?}

  # Significant constructs, longest/most-specific first so a `<cfscript>`/
  # `<cfquery>` block is captured whole before the generic single-tag branch.
  @construct Regex.compile!(
               "<cfscript\\b#{@tag_content}>.*?</cfscript\\s*>" <>
                 "|<cfquery\\b#{@tag_content}>.*?</cfquery\\s*>" <>
                 "|</?cf\\w+\\b#{@tag_content}/?>",
               "is"
             )

  @cfscript_re Regex.compile!("\\A<cfscript\\b#{@tag_content}>(.*)</cfscript\\s*>\\z", "is")

  ## Public API

  @doc "Convert `.cfm` template source into a `writeOutput`-emitting cfscript body."
  @spec convert(String.t()) :: String.t()
  def convert(source) do
    source
    |> strip_cf_comments()
    |> split_constructs()
    |> emit()
  end

  ## Tokenizing + emission

  # CFML comments `<!--- … --->` are removed (line-neutral). HTML comments
  # `<!-- … -->` are left as literal text so they render.
  @spec strip_cf_comments(String.t()) :: String.t()
  defp strip_cf_comments(source) do
    Regex.replace(~r/<!---.*?--->/s, source, &blank_lines/1)
  end

  # Split into alternating literal-text and construct pieces.
  @spec split_constructs(String.t()) :: [String.t()]
  defp split_constructs(source) do
    Regex.split(@construct, source, include_captures: true, trim: false)
  end

  @typep state :: %{in_output: boolean(), stack: [{:query | :plain, boolean()}]}

  @spec emit([String.t()]) :: String.t()
  defp emit(pieces) do
    {frags, _state} = Enum.reduce(pieces, {[], %{in_output: false, stack: []}}, &emit_piece/2)

    frags
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @spec emit_piece(String.t(), {[String.t()], state()}) :: {[String.t()], state()}
  defp emit_piece(piece, {frags, state}) do
    {fragment, state} = convert_piece(piece, state)
    {[fragment | frags], state}
  end

  # Classify a piece and produce its cfscript fragment (+ updated state).
  @spec convert_piece(String.t(), state()) :: {String.t(), state()}
  defp convert_piece(piece, state) do
    cond do
      not cf_construct?(piece) ->
        {write_text(piece, state.in_output), state}

      inner = script_inner(piece) ->
        {inner, state}

      starts_with_ci?(piece, "<cfoutput") and not close_tag?(piece) ->
        open_cfoutput(piece, state)

      starts_with_ci?(piece, "</cfoutput") ->
        close_cfoutput(state)

      starts_with_ci?(piece, "<cfinclude") ->
        {convert_cfinclude(piece), state}

      starts_with_ci?(piece, "<cfmodule") or starts_with_ci?(piece, "<cf_") ->
        {convert_cfmodule(piece), state}

      starts_with_ci?(piece, "<cfloop") and cfloop_query(piece) ->
        {cfloop_query(piece), state}

      true ->
        # A standard statement/control tag (cfif/cfloop/cfset/cfparam/cfswitch/
        # cfquery/…) — reuse TagConverter; unknown tags become loud markers.
        {TagConverter.convert_body(piece), state}
    end
  end

  # Is this piece one of the constructs the splitter captures (vs literal text)?
  @spec cf_construct?(String.t()) :: boolean()
  defp cf_construct?(piece), do: Regex.match?(~r/\A<\/?cf/i, piece)

  @spec script_inner(String.t()) :: String.t() | nil
  defp script_inner(piece) do
    case Regex.run(@cfscript_re, piece) do
      [_whole, inner] -> inner
      nil -> nil
    end
  end

  ## <cfoutput>

  @spec open_cfoutput(String.t(), state()) :: {String.t(), state()}
  defp open_cfoutput(piece, state) do
    case tag_attr(piece, "query") do
      nil ->
        {"", %{state | in_output: true, stack: [{:plain, state.in_output} | state.stack]}}

      query ->
        q = bare(query)
        frag = "for (#{q} in __exml_rows(#{q})) {"
        {frag, %{state | in_output: true, stack: [{:query, state.in_output} | state.stack]}}
    end
  end

  @spec close_cfoutput(state()) :: {String.t(), state()}
  defp close_cfoutput(%{stack: [{kind, prev} | rest]} = state) do
    frag = if kind == :query, do: "}", else: ""
    {frag, %{state | in_output: prev, stack: rest}}
  end

  # A stray `</cfoutput>` with no matching open: ignore it.
  defp close_cfoutput(state), do: {"", state}

  ## <cfinclude> / <cfmodule>

  @spec convert_cfinclude(String.t()) :: String.t()
  defp convert_cfinclude(piece) do
    case tag_attr(piece, "template") do
      nil -> ~s|__exml_unsupported("cfinclude without template=");|
      template -> "__exml_include(#{attr_expr(template)});"
    end
  end

  @spec convert_cfmodule(String.t()) :: String.t()
  defp convert_cfmodule(piece) do
    attrs = tag_attrs(piece)

    cond do
      template = Map.get(attrs, "template") ->
        rest = Map.drop(attrs, ["template"])
        "__exml_module(#{attr_expr(template)}, {#{attrs_struct(rest)}});"

      true ->
        # `name=`/`<cf_x>` resolution needs a configured customtags root — out of
        # scope for the self-contained-page milestone; fail loudly if reached.
        ~s|__exml_unsupported("cfmodule name=/<cf_*> custom tags not yet supported");|
    end
  end

  # `<cfloop query="q" …>` open → a row loop, or nil if not a query loop.
  @spec cfloop_query(String.t()) :: String.t() | nil
  defp cfloop_query(piece) do
    case tag_attr(piece, "query") do
      nil -> nil
      query -> "for (#{bare(query)} in __exml_rows(#{bare(query)})) {"
    end
  end

  ## Text → writeOutput

  # Emit literal text. Inside `<cfoutput>`, `#expr#` interpolates (only `"` is
  # escaped); outside, `#` is doubled so it stays literal.
  @spec write_text(String.t(), boolean()) :: String.t()
  defp write_text("", _in_output), do: ""

  defp write_text(text, true), do: ~s|writeOutput("#{escape_quotes(text)}");|

  defp write_text(text, false) do
    ~s|writeOutput("#{text |> escape_quotes() |> escape_hashes()}");|
  end

  @spec escape_quotes(String.t()) :: String.t()
  defp escape_quotes(text), do: String.replace(text, ~s("), ~s(""))

  @spec escape_hashes(String.t()) :: String.t()
  defp escape_hashes(text), do: String.replace(text, "#", "##")

  ## Attribute helpers (delegating parsing to TagConverter)

  @spec tag_attrs(String.t()) :: %{optional(String.t()) => String.t() | nil}
  defp tag_attrs(piece) do
    piece
    |> strip_tag_delimiters()
    |> TagConverter.attrs_map()
  end

  @spec tag_attr(String.t(), String.t()) :: String.t() | nil
  defp tag_attr(piece, name), do: tag_attrs(piece) |> Map.get(name)

  # Strip `<tagname` … `>` (and a leading `cf_`/`cf`) down to just the attribute
  # text, dropping the tag name so it isn't parsed as a boolean attribute.
  @spec strip_tag_delimiters(String.t()) :: String.t()
  defp strip_tag_delimiters(piece) do
    piece
    |> String.replace(~r/\A<\/?\s*[\w:.\-]+/, "")
    |> String.replace(~r/\/?>\s*\z/, "")
  end

  # Build a struct-literal body `a: expr, b: expr` from attributes.
  @spec attrs_struct(%{optional(String.t()) => String.t() | nil}) :: String.t()
  defp attrs_struct(attrs) do
    attrs
    |> Enum.map(fn {k, v} -> "#{k}: #{attr_expr(v || "")}" end)
    |> Enum.join(", ")
  end

  # An attribute value as a cfscript expression: a fully `#…#`-wrapped value is
  # the bare expression; anything else is a (possibly interpolated) string.
  @spec attr_expr(String.t()) :: String.t()
  defp attr_expr(value) do
    trimmed = String.trim(value)

    if Regex.match?(~r/\A#[^#]*#\z/, trimmed),
      do: bare(trimmed),
      else: ~s|"#{escape_quotes(value)}"|
  end

  @spec bare(String.t()) :: String.t()
  defp bare(value),
    do: value |> String.trim() |> String.trim_leading("#") |> String.trim_trailing("#")

  ## Misc

  @spec starts_with_ci?(String.t(), String.t()) :: boolean()
  defp starts_with_ci?(piece, prefix),
    do: piece |> String.downcase() |> String.starts_with?(prefix)

  @spec close_tag?(String.t()) :: boolean()
  defp close_tag?(piece), do: String.starts_with?(piece, "</")

  @spec blank_lines(String.t()) :: String.t()
  defp blank_lines(text) do
    text |> :binary.matches("\n") |> length() |> then(&String.duplicate("\n", &1))
  end
end
