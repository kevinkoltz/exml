defmodule ExML.CFScript.Loader do
  @moduledoc """
  Loads `.cfc` files into parsed `AST.Component`s, resolving CFML component
  paths (`cfc.foo.bar`) against a configured root directory and caching results.

  ## Tag/script unwrapping

  CFCs come in several shells: pure `component {}`, `<cfscript>`-wrapped
  script, and tag components (`<cfcomponent>` with embedded `<cfscript>` blocks
  and `<cffunction>` tags). The loader strips the comment/`<cfcomponent>`/
  `<cfscript>` shell and delegates `<cffunction>`-to-cfscript rewriting to
  `ExML.CFScript.TagConverter`.

  ## Lenient, function-by-function parsing

  Real CFCs contain many functions, some using cfscript features the
  interpreter doesn't support yet. Rather than fail the whole component, the
  loader tokenizes once, brace-matches each top-level `function` into its own
  token chunk, and parses each independently — skipping (with a logged warning)
  any that don't parse. This keeps the supported functions usable.
  """

  require Logger

  alias ExML.CFScript.{AST, Context, Lexer, Parser, TagConverter}

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

  @doc """
  Whether a component file exists for `path` (e.g. `"cfc.pkg.thing"`).

  Used to tell a leaf component (`cfc.foo` -> `foo.cfc`) from an intermediate
  package segment (`cfc.pkg` -> a directory, no `pkg.cfc`) when resolving a
  dotted path.
  """
  @spec exists?(String.t(), Context.t()) :: boolean()
  def exists?(path, %Context{} = ctx), do: File.exists?(file_for(path, ctx))

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
      |> Lexer.tokenize_lines()
      |> strip_component_wrapper()

    {functions, static_init} = parse_members_leniently(tokens, label, [], [])
    functions = attach_lines(functions, source)
    %AST.Component{functions: functions, extends: extends, static_init: static_init}
  end

  # Tag conversion rewrites the source and shifts lines, so the parsed AST can't
  # carry reliable positions. Instead, scan the *original* source for each
  # function's declaration line — accurate for both `<cffunction name="x">` (tag)
  # and `function x(` (cfscript) forms — and stamp it onto the function.
  @spec attach_lines([AST.Function.t()], String.t()) :: [AST.Function.t()]
  defp attach_lines(functions, source) do
    line_map = function_line_map(source)
    Enum.map(functions, fn f -> %{f | line: Map.get(line_map, String.downcase(f.name))} end)
  end

  @decl_re ~r/<cffunction\b[^>]*\bname\s*=\s*"([^"]+)"|(?:^|\s)function\s+([A-Za-z_]\w*)\s*\(/i
  @spec function_line_map(String.t()) :: %{optional(String.t()) => pos_integer()}
  defp function_line_map(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {text, line}, acc ->
      case Regex.run(@decl_re, text, capture: :all_but_first) do
        nil ->
          acc

        captures ->
          Map.put_new(acc, captures |> Enum.find(&(&1 != "")) |> String.downcase(), line)
      end
    end)
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
    # Blank (don't delete) multi-line comments so line numbers don't shift.
    |> blank(~r/<!---.*?--->/s)
    |> TagConverter.convert_cffunctions()
    |> strip(~r/<\/?cfcomponent\b[^>]*>/i)
    |> strip(~r/<\/?cfscript\s*>/i)
  end

  @spec strip(String.t(), Regex.t()) :: String.t()
  defp strip(source, regex), do: Regex.replace(regex, source, "")

  # Replace each match with just its newlines, preserving line numbers.
  @spec blank(String.t(), Regex.t()) :: String.t()
  defp blank(source, regex) do
    Regex.replace(regex, source, fn match ->
      match |> :binary.matches("\n") |> Enum.map_join(fn _ -> "\n" end)
    end)
  end

  ## Component wrapper / lenient function extraction

  # If the tokens open with `component [attrs] { ... }`, peel the wrapper and
  # capture the `extends` attribute; otherwise treat the tokens as a bare list
  # of member declarations.
  @spec strip_component_wrapper([Lexer.token()]) :: {String.t() | nil, [Lexer.token()]}
  defp strip_component_wrapper([{:ident, kw, _} = tok | rest]) do
    if String.downcase(kw) == "component" do
      {extends, after_attrs} = take_component_attrs(rest, nil)
      {extends, drop_outer_braces(after_attrs)}
    else
      {nil, [tok | rest]}
    end
  end

  defp strip_component_wrapper(tokens), do: {nil, tokens}

  @spec take_component_attrs([Lexer.token()], String.t() | nil) ::
          {String.t() | nil, [Lexer.token()]}
  defp take_component_attrs([{:op, "{", _} | _] = tokens, extends), do: {extends, tokens}

  defp take_component_attrs([{:ident, name, _}, {:op, "=", _}, {:string, val, _} | rest], extends) do
    extends = if String.downcase(name) == "extends", do: val, else: extends
    take_component_attrs(rest, extends)
  end

  defp take_component_attrs([{:ident, _n, _}, {:op, "=", _}, {_t, _v, _} | rest], extends),
    do: take_component_attrs(rest, extends)

  defp take_component_attrs(tokens, extends), do: {extends, tokens}

  # Drop the leading `{` and the matching trailing `}` of the component body.
  @spec drop_outer_braces([Lexer.token()]) :: [Lexer.token()]
  defp drop_outer_braces([{:op, "{", _} | rest]) do
    rest |> Enum.reverse() |> drop_trailing_close_brace() |> Enum.reverse()
  end

  defp drop_outer_braces(tokens), do: tokens

  defp drop_trailing_close_brace([{:op, "}", _} | rest]), do: rest
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
  defp collect_member([{:op, "{", _} | rest], leading) do
    if static_only?(leading) do
      {inner, after_block} = take_braced_block(rest, [], 1)
      {:static_init, inner, after_block}
    else
      collect_member(rest, [])
    end
  end

  defp collect_member([{:ident, word, _} = tok | rest], leading) do
    down = String.downcase(word)

    cond do
      down == "function" ->
        {body_tokens, after_body} = take_function_body(rest, [])
        {:function, Enum.reverse(leading) ++ [tok] ++ body_tokens, after_body}

      down in @modifier_words or down in @type_words ->
        collect_member(rest, [tok | leading])

      true ->
        member_after_ident(tok, rest)
    end
  end

  defp collect_member([_other | rest], _leading), do: collect_member(rest, [])

  # `name = function(...) {...}` at the top level is a method defined as a
  # function expression — rewrite it to a named declaration (`function name(...)
  # {...}`) so it loads like any other method. Anything else (`property`, a bare
  # variable assignment) is skipped to resync.
  @spec member_after_ident(Lexer.token(), [Lexer.token()]) ::
          {:function, [Lexer.token()], [Lexer.token()]}
          | {:static_init, [Lexer.token()], [Lexer.token()]}
          | :done
  defp member_after_ident(
         name_tok,
         [{:op, "=", _}, {:ident, fw, _} = fn_tok, {:op, "(", _} = paren | rest]
       ) do
    if String.downcase(fw) == "function" do
      {body_tokens, after_body} = take_function_body([fn_tok, paren | rest], [])
      {:function, [fn_tok, name_tok | tl(body_tokens)], after_body}
    else
      collect_member(rest, [])
    end
  end

  defp member_after_ident(_name_tok, rest), do: collect_member(rest, [])

  @spec static_only?([Lexer.token()]) :: boolean()
  defp static_only?([{:ident, word, _}]), do: String.downcase(word) == "static"
  defp static_only?(_leading), do: false

  # Collect tokens until the matching `}` (assuming the opening `{` was consumed).
  @spec take_braced_block([Lexer.token()], [Lexer.token()], non_neg_integer()) ::
          {[Lexer.token()], [Lexer.token()]}
  defp take_braced_block([], acc, _depth), do: {Enum.reverse(acc), []}

  defp take_braced_block([{:op, "{", _} = t | rest], acc, depth),
    do: take_braced_block(rest, [t | acc], depth + 1)

  defp take_braced_block([{:op, "}", _} | rest], acc, 1), do: {Enum.reverse(acc), rest}

  defp take_braced_block([{:op, "}", _} = t | rest], acc, depth),
    do: take_braced_block(rest, [t | acc], depth - 1)

  defp take_braced_block([t | rest], acc, depth), do: take_braced_block(rest, [t | acc], depth)

  # Capture tokens from just after `function` through the matching `}` of the
  # body. Tracks brace depth, ignoring everything until the first `{`.
  @spec take_function_body([Lexer.token()], [Lexer.token()]) ::
          {[Lexer.token()], [Lexer.token()]}
  defp take_function_body(tokens, acc), do: take_function_body(tokens, acc, :pre, 0)

  # :pre — before the body's opening brace; :body — inside the body.
  defp take_function_body([], acc, _state, _depth), do: {Enum.reverse(acc), []}

  defp take_function_body([{:op, "{", _} = t | rest], acc, :pre, _depth) do
    take_function_body(rest, [t | acc], :body, 1)
  end

  defp take_function_body([{:op, "{", _} = t | rest], acc, :body, depth) do
    take_function_body(rest, [t | acc], :body, depth + 1)
  end

  defp take_function_body([{:op, "}", _} = t | rest], acc, :body, 1) do
    {Enum.reverse([t | acc]), rest}
  end

  defp take_function_body([{:op, "}", _} = t | rest], acc, :body, depth) do
    take_function_body(rest, [t | acc], :body, depth - 1)
  end

  defp take_function_body([t | rest], acc, state, depth) do
    take_function_body(rest, [t | acc], state, depth)
  end
end
