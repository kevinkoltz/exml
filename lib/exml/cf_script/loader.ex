defmodule ExML.CFScript.Loader do
  @moduledoc """
  Loads `.cfc` files into parsed `AST.Component`s, resolving CFML component
  paths (`cfc.foo.bar`) against a configured root directory and caching results.

  ## Tag/script unwrapping

  CFCs come in several shells: pure `component {}`, `<cfscript>`-wrapped
  script, and tag components (`<cfcomponent>` with embedded `<cfscript>` blocks
  and `<cffunction>` tags). The loader strips the comment/`<cfcomponent>`/
  `<cfscript>` shell and rewrites each `<cffunction>` into an equivalent
  cfscript `function` declaration.

  ## `<cffunction>` conversion

  A `<cffunction>` is rewritten to `function name(params) { body }`:
  `<cfargument>` tags become the parameter list, a `<cfscript>` body is
  unwrapped, and the supported tag statements (`<cfset>`, `<cfreturn>`,
  `<cfif>`/`<cfelseif>`/`<cfelse>`, `<cfswitch>`/`<cfcase>`/`<cfdefaultcase>`)
  are translated to cfscript. A function whose body still contains an
  unconverted `<cf...>` tag (e.g. `<cfquery>`, `<cfloop>`) is dropped rather
  than emitted as broken source — the lenient parser would skip it anyway, and
  dropping it keeps the stray tag tokens from corrupting sibling functions.

  ## Lenient, function-by-function parsing

  Real CFCs contain many functions, some using cfscript features the
  interpreter doesn't support yet. Rather than fail the whole component, the
  loader tokenizes once, brace-matches each top-level `function` into its own
  token chunk, and parses each independently — skipping (with a logged warning)
  any that don't parse. This keeps the supported functions usable.
  """

  require Logger

  alias ExML.CFScript.{AST, Context, Lexer, Parser}

  @doc """
  Load and parse the component at `path` (e.g. `"cfc.common"`), using the
  context's cache and `cfc_root`.
  """
  @spec load(String.t(), Context.t()) :: AST.Component.t()
  def load(path, %Context{cache: cache} = ctx) do
    case Agent.get(cache, &Map.get(&1, path)) do
      nil ->
        component = parse_file(file_for(path, ctx))
        Agent.update(cache, &Map.put(&1, path, component))
        component

      component ->
        component
    end
  end

  @doc "Parse a `.cfc` file from disk into an `AST.Component`."
  @spec parse_file(String.t()) :: AST.Component.t()
  def parse_file(file) do
    file
    |> File.read!()
    |> parse_source(file)
  end

  @doc "Parse `.cfc` source (preprocessing tags), labeling errors with `label`."
  @spec parse_source(String.t(), String.t()) :: AST.Component.t()
  def parse_source(source, label \\ "<source>") do
    {extends, tokens} =
      source
      |> preprocess()
      |> Lexer.tokenize()
      |> strip_component_wrapper()

    {functions, static_init} = parse_members_leniently(tokens, label, [], [])
    %AST.Component{functions: functions, extends: extends, static_init: static_init}
  end

  ## File resolution

  # `cfc.foo.bar` → "<cfc_root>/foo/bar.cfc". The leading `cfc` mapping segment
  # maps to cfc_root itself.
  @spec file_for(String.t(), Context.t()) :: String.t()
  defp file_for(path, %Context{cfc_root: root}) do
    segments =
      case String.split(path, ".") do
        ["cfc" | rest] -> rest
        other -> other
      end

    Path.join([root | segments]) <> ".cfc"
  end

  ## Tag preprocessing

  @spec preprocess(String.t()) :: String.t()
  defp preprocess(source) do
    source
    |> strip(~r/<!---.*?--->/s)
    |> convert_cffunctions()
    |> strip(~r/<\/?cfcomponent\b[^>]*>/i)
    |> strip(~r/<\/?cfscript\s*>/i)
  end

  @spec strip(String.t(), Regex.t()) :: String.t()
  defp strip(source, regex), do: Regex.replace(regex, source, "")

  # Rewrite each `<cffunction>...</cffunction>` to a cfscript `function`.
  @spec convert_cffunctions(String.t()) :: String.t()
  defp convert_cffunctions(source) do
    Regex.replace(~r/<cffunction\b([^>]*)>(.*?)<\/cffunction>/si, source, fn _whole,
                                                                             attrs,
                                                                             inner ->
      convert_one_function(attrs, inner)
    end)
  end

  @spec convert_one_function(String.t(), String.t()) :: String.t()
  defp convert_one_function(attrs, inner) do
    case Map.get(parse_attrs(attrs), "name") do
      nil ->
        ""

      name ->
        {params, body} = extract_arguments(inner)
        converted = convert_tag_body(body)
        source = "function #{name}(#{params}) {\n#{converted}\n}\n"
        if emittable?(converted, source), do: source, else: ""
    end
  end

  # Only emit a converted function if (a) its body has no leftover unconverted
  # CF tag and (b) it lexes cleanly on its own. The whole component is lexed in
  # one pass, so a function with an unbalanced quote or `#` interpolation would
  # otherwise corrupt the lexer state for every sibling that follows it. A
  # function that lexes standalone but doesn't parse is still emitted — the
  # lenient parser drops it later without affecting siblings.
  @spec emittable?(String.t(), String.t()) :: boolean()
  defp emittable?(converted_body, source) do
    not Regex.match?(~r/<\s*\/?\s*cf/i, converted_body) and lexes?(source)
  end

  @spec lexes?(String.t()) :: boolean()
  defp lexes?(source) do
    Lexer.tokenize(source)
    true
  rescue
    _error -> false
  end

  # Pull `<cfargument>` tags into a cfscript parameter list and return the body
  # with those tags removed.
  @spec extract_arguments(String.t()) :: {String.t(), String.t()}
  defp extract_arguments(inner) do
    params =
      ~r/<cfargument\b([^>]*)>/i
      |> Regex.scan(inner)
      |> Enum.map(fn [_whole, attrs] -> param_decl(parse_attrs(attrs)) end)
      |> Enum.join(", ")

    {params, strip(inner, ~r/<cfargument\b[^>]*>/i)}
  end

  # `<cfargument name= [type=] [required=] [default=]>` -> `[required] [type] name [= default]`.
  @spec param_decl(%{optional(String.t()) => String.t()}) :: String.t()
  defp param_decl(attrs) do
    type = Map.get(attrs, "type")
    type = if type in [nil, "", "any"], do: nil, else: String.downcase(type)
    default = Map.get(attrs, "default")

    [
      if(truthy_attr?(Map.get(attrs, "required")), do: "required"),
      type,
      Map.fetch!(attrs, "name"),
      if(default, do: "= " <> literal(default))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # A tag's inner text up to its real closing `>`. A `>` (or `<`) inside a
  # single- or double-quoted string (CFML doubles an embedded quote) does not
  # close the tag — so `<cfset x = replace(s, "&gt;", ">", "all")>` is captured
  # whole instead of truncating at the `>` inside `">"`.
  @tag_content ~S{(?:[^>"']|"(?:""|[^"])*"|'(?:''|[^'])*')*?}
  @cfset_re Regex.compile!("<cfset\\s+(#{@tag_content})\\s*/?>", "i")
  @cfreturn_expr_re Regex.compile!("<cfreturn\\s+(#{@tag_content})\\s*/?>", "i")
  @cfif_re Regex.compile!("<cfif\\b(#{@tag_content})>", "i")
  @cfelseif_re Regex.compile!("<cfelseif\\b(#{@tag_content})>", "i")
  @cfswitch_re Regex.compile!("<cfswitch\\b(#{@tag_content})>", "i")
  @cfcase_re Regex.compile!("<cfcase\\b(#{@tag_content})>", "i")

  # Translate the tag statements we support into cfscript. Unsupported tags are
  # left intact so the caller can detect and drop the function.
  @spec convert_tag_body(String.t()) :: String.t()
  defp convert_tag_body(body) do
    body
    |> strip(~r/<\/?cfscript\s*>/i)
    |> sub(@cfset_re, fn _whole, expr -> "#{expr};" end)
    |> sub(@cfreturn_expr_re, fn _whole, expr -> "return #{expr};" end)
    |> strip_to(~r/<cfreturn\s*\/?>/i, "return;")
    |> sub(@cfelseif_re, fn _whole, cond -> "} else if (#{cond}) {" end)
    |> strip_to(~r/<cfelse\s*\/?>/i, "} else {")
    |> sub(@cfif_re, fn _whole, cond -> "if (#{cond}) {" end)
    |> strip_to(~r/<\/cfif\s*>/i, "}")
    |> convert_switch_tags()
  end

  @spec convert_switch_tags(String.t()) :: String.t()
  defp convert_switch_tags(body) do
    body
    |> sub(@cfswitch_re, fn _whole, attrs ->
      expr = parse_attrs(attrs) |> Map.get("expression", "") |> strip_hashes()
      "switch (#{expr}) {"
    end)
    |> sub(@cfcase_re, fn _whole, attrs ->
      value = parse_attrs(attrs) |> Map.get("value", "")
      "case #{literal(value)}: "
    end)
    |> strip_to(~r/<\/cfcase\s*>/i, " break; ")
    |> strip_to(~r/<cfdefaultcase\s*>/i, "default: ")
    |> strip_to(~r/<\/cfdefaultcase\s*>/i, " break; ")
    |> strip_to(~r/<\/cfswitch\s*>/i, "}")
  end

  # Source-first wrappers around `Regex.replace/3` (so they compose in a pipe).
  @spec sub(String.t(), Regex.t(), (String.t(), String.t() -> String.t())) :: String.t()
  defp sub(source, regex, fun), do: Regex.replace(regex, source, fun)

  @spec strip_to(String.t(), Regex.t(), String.t()) :: String.t()
  defp strip_to(source, regex, replacement), do: Regex.replace(regex, source, replacement)

  # Parse `key="value"` attribute pairs into a map of downcased key => value.
  @spec parse_attrs(String.t()) :: %{optional(String.t()) => String.t()}
  defp parse_attrs(attrs) do
    ~r/([a-zA-Z_]\w*)\s*=\s*"([^"]*)"/
    |> Regex.scan(attrs)
    |> Map.new(fn [_whole, key, value] -> {String.downcase(key), value} end)
  end

  # Render an attribute value as a cfscript literal: numbers/booleans bare,
  # everything else as a double-quoted string (CFML doubles embedded quotes).
  @spec literal(String.t()) :: String.t()
  defp literal(value) do
    cond do
      Regex.match?(~r/^-?\d+(\.\d+)?$/, value) -> value
      String.downcase(value) in ["true", "false"] -> String.downcase(value)
      true -> ~s("#{String.replace(value, "\"", "\"\"")}")
    end
  end

  @spec truthy_attr?(String.t() | nil) :: boolean()
  defp truthy_attr?(nil), do: false
  defp truthy_attr?(value), do: String.downcase(value) in ["true", "yes"]

  @spec strip_hashes(String.t()) :: String.t()
  defp strip_hashes(value),
    do: value |> String.trim() |> String.trim_leading("#") |> String.trim_trailing("#")

  ## Component wrapper / lenient function extraction

  # If the tokens open with `component [attrs] { ... }`, peel the wrapper and
  # capture the `extends` attribute; otherwise treat the tokens as a bare list
  # of member declarations.
  @spec strip_component_wrapper([Lexer.token()]) :: {String.t() | nil, [Lexer.token()]}
  defp strip_component_wrapper([{:ident, kw} | rest]) do
    if String.downcase(kw) == "component" do
      {extends, after_attrs} = take_component_attrs(rest, nil)
      {extends, drop_outer_braces(after_attrs)}
    else
      {nil, [{:ident, kw} | rest]}
    end
  end

  defp strip_component_wrapper(tokens), do: {nil, tokens}

  @spec take_component_attrs([Lexer.token()], String.t() | nil) ::
          {String.t() | nil, [Lexer.token()]}
  defp take_component_attrs([{:op, "{"} | _] = tokens, extends), do: {extends, tokens}

  defp take_component_attrs([{:ident, name}, {:op, "="}, {:string, val} | rest], extends) do
    extends = if String.downcase(name) == "extends", do: val, else: extends
    take_component_attrs(rest, extends)
  end

  defp take_component_attrs([{:ident, _n}, {:op, "="}, {_t, _v} | rest], extends),
    do: take_component_attrs(rest, extends)

  defp take_component_attrs(tokens, extends), do: {extends, tokens}

  # Drop the leading `{` and the matching trailing `}` of the component body.
  @spec drop_outer_braces([Lexer.token()]) :: [Lexer.token()]
  defp drop_outer_braces([{:op, "{"} | rest]) do
    rest |> Enum.reverse() |> drop_trailing_close_brace() |> Enum.reverse()
  end

  defp drop_outer_braces(tokens), do: tokens

  defp drop_trailing_close_brace([{:op, "}"} | rest]), do: rest
  defp drop_trailing_close_brace(tokens), do: tokens

  # Walk top-level tokens, carving each member into its own chunk: a function
  # (parsed leniently — an unparseable one is skipped) or a `static { ... }`
  # initializer block (whose statements accumulate into static_init).
  @spec parse_members_leniently([Lexer.token()], String.t(), [AST.Function.t()], [tuple()]) ::
          {[AST.Function.t()], [tuple()]}
  defp parse_members_leniently(tokens, label, funcs, static_init) do
    case next_member_chunk(tokens) do
      :done ->
        {Enum.reverse(funcs), static_init}

      {:function, chunk, rest} ->
        funcs = parse_one_function_lenient(chunk, label, funcs)
        parse_members_leniently(rest, label, funcs, static_init)

      {:static_init, inner, rest} ->
        parse_members_leniently(
          rest,
          label,
          funcs,
          static_init ++ parse_static_init(inner, label)
        )
    end
  end

  @spec parse_one_function_lenient([Lexer.token()], String.t(), [AST.Function.t()]) ::
          [AST.Function.t()]
  defp parse_one_function_lenient(chunk, label, funcs) do
    [Parser.parse_one_function(chunk) | funcs]
  rescue
    e ->
      Logger.debug(
        "ExML.CFScript.Loader: skipping unparseable function in #{label}: #{Exception.message(e)}"
      )

      funcs
  end

  @spec parse_static_init([Lexer.token()], String.t()) :: [tuple()]
  defp parse_static_init(inner, label) do
    Parser.parse_statements_from_tokens(inner)
  rescue
    e ->
      Logger.debug(
        "ExML.CFScript.Loader: skipping unparseable static block in #{label}: #{Exception.message(e)}"
      )

      []
  end

  # Collect leading modifier idents until either a `function` keyword (a function
  # member) or a `{` directly after `static` (a static initializer block).
  @spec next_member_chunk([Lexer.token()]) ::
          {:function, [Lexer.token()], [Lexer.token()]}
          | {:static_init, [Lexer.token()], [Lexer.token()]}
          | :done
  defp next_member_chunk(tokens), do: collect_member(tokens, [])

  @modifier_words ~w(static public private package remote final abstract)
  @type_words ~w(any void string numeric boolean date datetime array struct query component binary guid uuid)

  defp collect_member([], _leading), do: :done

  # `static {` — a static initializer block (leading is exactly `static`).
  defp collect_member([{:op, "{"} | rest], leading) do
    if static_only?(leading) do
      {inner, after_block} = take_braced_block(rest, [], 1)
      {:static_init, inner, after_block}
    else
      collect_member(rest, [])
    end
  end

  defp collect_member([{:ident, word} | rest], leading) do
    down = String.downcase(word)

    cond do
      down == "function" ->
        {body_tokens, after_body} = take_function_body(rest, [])
        {:function, Enum.reverse(leading) ++ [{:ident, word}] ++ body_tokens, after_body}

      down in @modifier_words or down in @type_words ->
        collect_member(rest, [{:ident, word} | leading])

      true ->
        # Unexpected top-level ident (e.g. a `property` statement); drop the
        # accumulated leading tokens and skip this one token to resync.
        collect_member(rest, [])
    end
  end

  defp collect_member([_other | rest], _leading), do: collect_member(rest, [])

  @spec static_only?([Lexer.token()]) :: boolean()
  defp static_only?([{:ident, word}]), do: String.downcase(word) == "static"
  defp static_only?(_leading), do: false

  # Collect tokens until the matching `}` (assuming the opening `{` was consumed).
  @spec take_braced_block([Lexer.token()], [Lexer.token()], non_neg_integer()) ::
          {[Lexer.token()], [Lexer.token()]}
  defp take_braced_block([], acc, _depth), do: {Enum.reverse(acc), []}

  defp take_braced_block([{:op, "{"} = t | rest], acc, depth),
    do: take_braced_block(rest, [t | acc], depth + 1)

  defp take_braced_block([{:op, "}"} | rest], acc, 1), do: {Enum.reverse(acc), rest}

  defp take_braced_block([{:op, "}"} = t | rest], acc, depth),
    do: take_braced_block(rest, [t | acc], depth - 1)

  defp take_braced_block([t | rest], acc, depth), do: take_braced_block(rest, [t | acc], depth)

  # Capture tokens from just after `function` through the matching `}` of the
  # body. Tracks brace depth, ignoring everything until the first `{`.
  @spec take_function_body([Lexer.token()], [Lexer.token()]) ::
          {[Lexer.token()], [Lexer.token()]}
  defp take_function_body(tokens, acc), do: take_function_body(tokens, acc, :pre, 0)

  # :pre — before the body's opening brace; :body — inside the body.
  defp take_function_body([], acc, _state, _depth), do: {Enum.reverse(acc), []}

  defp take_function_body([{:op, "{"} = t | rest], acc, :pre, _depth) do
    take_function_body(rest, [t | acc], :body, 1)
  end

  defp take_function_body([{:op, "{"} = t | rest], acc, :body, depth) do
    take_function_body(rest, [t | acc], :body, depth + 1)
  end

  defp take_function_body([{:op, "}"} = t | rest], acc, :body, 1) do
    {Enum.reverse([t | acc]), rest}
  end

  defp take_function_body([{:op, "}"} = t | rest], acc, :body, depth) do
    take_function_body(rest, [t | acc], :body, depth - 1)
  end

  defp take_function_body([t | rest], acc, state, depth) do
    take_function_body(rest, [t | acc], state, depth)
  end
end
