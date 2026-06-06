defmodule ExML.CFScript.Loader do
  @moduledoc """
  Loads `.cfc` files into parsed `AST.Component`s, resolving CFML component
  paths (`cfc.foo.bar`) against a configured root directory and caching results.

  ## Tag/script unwrapping

  Signal CFCs come in several shells: pure `component {}`, `<cfscript>`-wrapped
  script, and tag components (`<cfcomponent>` with embedded `<cfscript>` blocks
  and `<cffunction>` tags). The loader strips the tag shell (`<!--- --->`
  comments, `<cffunction>...</cffunction>` blocks, and the
  `<cfcomponent>`/`<cfscript>` wrappers) before parsing the cfscript inside.

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

    functions = parse_functions_leniently(tokens, label, [])
    %AST.Component{functions: functions, extends: extends}
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
    |> strip(~r/<cffunction\b.*?<\/cffunction>/si)
    |> strip(~r/<\/?cfcomponent\b[^>]*>/i)
    |> strip(~r/<\/?cfscript\s*>/i)
  end

  @spec strip(String.t(), Regex.t()) :: String.t()
  defp strip(source, regex), do: Regex.replace(regex, source, "")

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

  # Walk top-level tokens, carving each function into its own chunk and parsing
  # it. Leading modifier idents accumulate until a `function` keyword; the chunk
  # then runs through the brace-matched body.
  @spec parse_functions_leniently([Lexer.token()], String.t(), [AST.Function.t()]) ::
          [AST.Function.t()]
  defp parse_functions_leniently(tokens, label, acc) do
    case next_function_chunk(tokens) do
      :done ->
        Enum.reverse(acc)

      {chunk, rest} ->
        acc =
          try do
            [Parser.parse_one_function(chunk) | acc]
          rescue
            e ->
              Logger.debug(
                "ExML.CFScript.Loader: skipping unparseable function in #{label}: " <>
                  Exception.message(e)
              )

              acc
          end

        parse_functions_leniently(rest, label, acc)
    end
  end

  # Find the next function: collect leading modifier idents, then on the
  # `function` keyword, brace-match its body and return {chunk_tokens, rest}.
  @spec next_function_chunk([Lexer.token()]) :: {[Lexer.token()], [Lexer.token()]} | :done
  defp next_function_chunk(tokens), do: collect_until_function(tokens, [])

  @modifier_words ~w(static public private package remote final abstract)
  @type_words ~w(any void string numeric boolean date datetime array struct query component binary guid uuid)

  defp collect_until_function([], _leading), do: :done

  defp collect_until_function([{:ident, word} | rest], leading) do
    down = String.downcase(word)

    cond do
      down == "function" ->
        {body_tokens, after_body} = take_function_body(rest, [])
        {Enum.reverse(leading) ++ [{:ident, word}] ++ body_tokens, after_body}

      down in @modifier_words or down in @type_words ->
        collect_until_function(rest, [{:ident, word} | leading])

      true ->
        # Unexpected top-level ident (e.g. a `property` statement); drop the
        # accumulated leading tokens and skip this one token to resync.
        collect_until_function(rest, [])
    end
  end

  defp collect_until_function([_other | rest], _leading), do: collect_until_function(rest, [])

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
