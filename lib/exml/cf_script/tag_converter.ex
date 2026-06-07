defmodule ExML.CFScript.TagConverter do
  @moduledoc """
  Rewrites CFML *tag* syntax into the cfscript the rest of the engine parses.

  Legacy CFML codebases are largely tag-based (`<cffunction>`, `<cfset>`,
  `<cfquery>`, ...). This module converts each `<cffunction>` into a cfscript
  `function`, its
  `<cfargument>`s into parameters, and the supported tag statements in the body
  into cfscript. A function whose body still contains an unconverted `<cf...>`
  tag — or that does not lex cleanly on its own — is dropped rather than emitted
  as broken source, which keeps stray tag tokens from corrupting sibling
  functions (the whole component is lexed in one pass).

  ## Attribute parsing

  Attributes are parsed the way Lucee's tag tokenizer does: a value may be
  double-quoted (`name="x"`, doubled `""` escapes a quote), single-quoted
  (`name='x'`), unquoted (`name=x`, `localmode=true`, `value=#expr#`), or absent
  for a boolean attribute (`output`). Keys are matched case-insensitively.

  ## Supported tags

  Control flow (`<cfif>`/`<cfelseif>`/`<cfelse>`, `<cfloop>`,
  `<cfswitch>`/`<cfcase>`/`<cfdefaultcase>`, `<cftry>`/`<cfcatch>`/`<cffinally>`),
  statements (`<cfset>`, `<cfreturn>`, `<cfthrow>`, `<cfrethrow>`, `<cfabort>`,
  `<cfbreak>`, `<cfcontinue>`, `<cfparam>`), and block content (`<cfquery>` with
  `<cfqueryparam>` → `queryExecute`, `<cfsavecontent>` → a string assignment).
  `<cftransaction>`/`<cfoutput>` are unwrapped; `<cfmail>`/`<cfdump>`/`<cflog>`
  (side-effecting tags we don't model) are dropped.
  """

  alias ExML.CFScript.Lexer

  # A tag's inner text up to its real closing `>`. A `>` (or `<`) inside a
  # single- or double-quoted string (CFML doubles an embedded quote) doesn't
  # close the tag, so `<cfset x = replace(s, "&gt;", ">", "all")>` is captured
  # whole instead of truncating at the `>` inside `">"`.
  @tag_content ~S{(?:[^>"']|"(?:""|[^"])*"|'(?:''|[^'])*')*?}

  # Attribute: key, then optionally `= value` (quoted/single/unquoted).
  @attr_re ~r/([\w:.\-]+)\s*(?:=\s*("(?:""|[^"])*"|'(?:''|[^'])*'|[^\s>]+))?/

  @cfset_re Regex.compile!("<cfset\\s+(#{@tag_content})\\s*/?>", "i")
  @cfreturn_expr_re Regex.compile!("<cfreturn\\s+(#{@tag_content})\\s*/?>", "i")
  @cfif_re Regex.compile!("<cfif\\b(#{@tag_content})>", "i")
  @cfelseif_re Regex.compile!("<cfelseif\\b(#{@tag_content})>", "i")
  @cfswitch_re Regex.compile!("<cfswitch\\b(#{@tag_content})>", "i")
  @cfcase_re Regex.compile!("<cfcase\\b(#{@tag_content})>", "i")
  @cfloop_re Regex.compile!("<cfloop\\b(#{@tag_content})>", "i")
  @cfthrow_re Regex.compile!("<cfthrow\\b(#{@tag_content})\\s*/?>", "i")
  @cfparam_re Regex.compile!("<cfparam\\b(#{@tag_content})\\s*/?>", "i")
  @cfcatch_re Regex.compile!("<cfcatch\\b(#{@tag_content})>", "i")
  @cfquery_re Regex.compile!("<cfquery\\b(#{@tag_content})>(.*?)</cfquery>", "is")
  @cfqueryparam_re Regex.compile!("<cfqueryparam\\b(#{@tag_content})\\s*/?>", "i")
  @cfsavecontent_re Regex.compile!(
                      "<cfsavecontent\\b(#{@tag_content})>(.*?)</cfsavecontent>",
                      "is"
                    )
  @cfmail_re Regex.compile!("<cfmail\\b(#{@tag_content})>(.*?)</cfmail>", "is")
  @cfinvoke_re Regex.compile!("<cfinvoke\\b(#{@tag_content})>(.*?)</cfinvoke>", "is")
  @cfinvoke_self_re Regex.compile!("<cfinvoke\\b(#{@tag_content})/>", "i")
  @cfinvokearg_re Regex.compile!("<cfinvokeargument\\b(#{@tag_content})\\s*/?>", "i")
  @cfargument_re Regex.compile!("<cfargument\\b(#{@tag_content})>", "i")
  @cffunction_re Regex.compile!("<cffunction\\b(#{@tag_content})>(.*?)</cffunction>", "is")

  ## Public API

  @doc "Rewrite every `<cffunction>...</cffunction>` in `source` to cfscript."
  @spec convert_cffunctions(String.t()) :: String.t()
  def convert_cffunctions(source) do
    Regex.replace(@cffunction_re, source, fn _whole, attrs, inner ->
      convert_one_function(attrs, inner)
    end)
  end

  @doc """
  Parse a tag's attribute string into an ordered `[{key, value}]` list. `value`
  is the unquoted string, or `nil` for a boolean attribute with no value.
  """
  @spec parse_attrs(String.t()) :: [{String.t(), String.t() | nil}]
  def parse_attrs(attrs) do
    @attr_re
    |> Regex.scan(attrs)
    |> Enum.map(fn [full, key | rest] ->
      if String.contains?(full, "="),
        do: {String.downcase(key), unquote_attr(List.first(rest) || "")},
        else: {String.downcase(key), nil}
    end)
    |> Enum.reject(fn {key, _value} -> key == "" end)
  end

  @doc "Attribute string as a map of downcased key => value (`nil` for boolean)."
  @spec attrs_map(String.t()) :: %{optional(String.t()) => String.t() | nil}
  def attrs_map(attrs), do: attrs |> parse_attrs() |> Map.new()

  ## <cffunction> -> function

  @spec convert_one_function(String.t(), String.t()) :: String.t()
  defp convert_one_function(attrs_str, inner) do
    attrs = attrs_map(attrs_str)

    case Map.get(attrs, "name") do
      nil ->
        ""

      name ->
        {params, body} = extract_arguments(inner)
        converted = convert_body(body)
        source = "function #{name}(#{params}) #{function_suffix(attrs)}{\n#{converted}\n}\n"
        if emittable?(converted, source), do: source, else: ""
    end
  end

  # The `localmode` modifier carries over (it decides unscoped-assignment scope);
  # `true`/`modern` enable it. Other `<cffunction>` attributes don't affect
  # execution and are dropped.
  @spec function_suffix(%{optional(String.t()) => String.t() | nil}) :: String.t()
  defp function_suffix(attrs) do
    case Map.fetch(attrs, "localmode") do
      :error -> ""
      # bare `localmode` (no value) means enabled
      {:ok, nil} -> "localmode=\"true\" "
      {:ok, value} -> "localmode=#{quoted(value)} "
    end
  end

  # Only emit a converted function if (a) its body has no leftover unconverted CF
  # tag and (b) it lexes cleanly on its own. A function that lexes but doesn't
  # parse is still emitted — the lenient parser drops it later in isolation.
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

  # Pull `<cfargument>` tags into a parameter list; return {params, body}.
  @spec extract_arguments(String.t()) :: {String.t(), String.t()}
  defp extract_arguments(inner) do
    params =
      @cfargument_re
      |> Regex.scan(inner)
      |> Enum.map(fn [_whole, attrs] -> param_decl(attrs_map(attrs)) end)
      |> Enum.join(", ")

    {params, Regex.replace(@cfargument_re, inner, "")}
  end

  # `<cfargument name= [type=] [required=] [default=]>` -> `[required] [type] name [= default]`.
  @spec param_decl(%{optional(String.t()) => String.t() | nil}) :: String.t()
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

  ## Body conversion

  @doc "Convert the tag statements in a (function) body to cfscript."
  @spec convert_body(String.t()) :: String.t()
  def convert_body(body) do
    body
    |> strip(~r/<\/?cfscript\s*>/i)
    # Block-content tags first: their bodies are SQL/template text that must be
    # captured before the statement transforms rewrite anything inside them.
    |> convert_cfquery()
    |> convert_cfsavecontent()
    |> convert_cfinvoke()
    |> strip(@cfmail_re)
    |> strip(~r/<cfdump\b#{@tag_content}\s*\/?>/i)
    |> strip(~r/<cflog\b#{@tag_content}\s*\/?>/i)
    # Unwrap wrapper tags (run the body as-is).
    |> strip(~r/<\/?cfoutput\b(#{@tag_content})?>/i)
    |> strip(~r/<\/?cftransaction\b(#{@tag_content})?>/i)
    # try/catch/finally
    |> strip_to(~r/<cftry\b(#{@tag_content})?>/i, "try {")
    |> sub(@cfcatch_re, fn _whole, attrs ->
      type = attrs_map(attrs) |> Map.get("type") |> catch_type()
      "} catch (#{type} cfcatch) {"
    end)
    |> strip(~r/<\/cfcatch\s*>/i)
    |> strip_to(~r/<cffinally\s*>/i, "} finally {")
    |> strip(~r/<\/cffinally\s*>/i)
    |> strip_to(~r/<\/cftry\s*>/i, "}")
    # Statement tags
    |> sub(@cfthrow_re, fn _whole, attrs -> convert_cfthrow(attrs) end)
    |> sub(@cfparam_re, fn _whole, attrs -> convert_cfparam(attrs) end)
    |> strip_to(~r/<cfrethrow\s*\/?>/i, "throw(message = cfcatch.message, type = cfcatch.type);")
    |> strip_to(~r/<cfabort\b(#{@tag_content})?\s*\/?>/i, "throw(message = \"cfabort\");")
    |> strip_to(~r/<cfbreak\s*\/?>/i, "break;")
    |> strip_to(~r/<cfcontinue\s*\/?>/i, "continue;")
    |> sub(@cfset_re, fn _whole, expr -> "#{expr};" end)
    |> sub(@cfreturn_expr_re, fn _whole, expr -> "return #{expr};" end)
    |> strip_to(~r/<cfreturn\s*\/?>/i, "return;")
    |> sub(@cfelseif_re, fn _whole, cond -> "} else if (#{cond}) {" end)
    |> strip_to(~r/<cfelse\s*\/?>/i, "} else {")
    |> sub(@cfif_re, fn _whole, cond -> "if (#{cond}) {" end)
    |> strip_to(~r/<\/cfif\s*>/i, "}")
    |> convert_switch_tags()
    |> convert_loop_tags()
  end

  ## <cfquery> -> queryExecute

  @spec convert_cfquery(String.t()) :: String.t()
  defp convert_cfquery(body) do
    Regex.replace(@cfquery_re, body, fn _whole, attrs, sql ->
      {converted_sql, params} = convert_queryparams(sql)
      call = "queryExecute(#{quoted(converted_sql)}, {#{params}})"

      case attrs_map(attrs) |> Map.get("name") do
        nil -> "#{call};\n"
        name -> "#{name} = #{call};\n"
      end
    end)
  end

  # Replace each `<cfqueryparam value="#x#" cfsqltype="cf_sql_int">` with a named
  # placeholder `:qpN`, collecting `qpN: {value: x, sqltype: "int"}` entries.
  @spec convert_queryparams(String.t()) :: {String.t(), String.t()}
  defp convert_queryparams(sql) do
    {converted, params, _n} =
      @cfqueryparam_re
      |> Regex.split(sql, include_captures: true)
      |> Enum.reduce({"", [], 1}, fn segment, {acc_sql, acc_params, n} ->
        case Regex.run(@cfqueryparam_re, segment) do
          [_whole, attrs] ->
            {acc_sql <> ":qp#{n}", [queryparam_entry(n, attrs_map(attrs)) | acc_params], n + 1}

          nil ->
            {acc_sql <> segment, acc_params, n}
        end
      end)

    {converted, params |> Enum.reverse() |> Enum.join(", ")}
  end

  @spec queryparam_entry(pos_integer(), %{optional(String.t()) => String.t() | nil}) :: String.t()
  defp queryparam_entry(n, attrs) do
    fields =
      [
        "value: #{attr_expr(Map.get(attrs, "value", ""))}",
        sqltype_field(Map.get(attrs, "cfsqltype") || Map.get(attrs, "sqltype")),
        if(truthy_attr?(Map.get(attrs, "list")), do: "list: true")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "qp#{n}: {#{fields}}"
  end

  @spec sqltype_field(String.t() | nil) :: String.t() | nil
  defp sqltype_field(nil), do: nil
  # cf_sql_integer -> "integer"
  defp sqltype_field(type),
    do: ~s|sqltype: "#{type |> String.downcase() |> String.replace_prefix("cf_sql_", "")}"|

  ## <cfsavecontent> -> string assignment

  @spec convert_cfsavecontent(String.t()) :: String.t()
  defp convert_cfsavecontent(body) do
    Regex.replace(@cfsavecontent_re, body, fn _whole, attrs, content ->
      case attrs_map(attrs) |> Map.get("variable") do
        nil -> ""
        var -> "#{var} = #{quoted(content)};\n"
      end
    end)
  end

  ## <cfinvoke> -> method call

  @spec convert_cfinvoke(String.t()) :: String.t()
  defp convert_cfinvoke(body) do
    body
    |> sub(@cfinvoke_re, fn _whole, attrs, inner -> build_invoke(attrs_map(attrs), inner) end)
    |> sub(@cfinvoke_self_re, fn _whole, attrs -> build_invoke(attrs_map(attrs), "") end)
  end

  @spec build_invoke(%{optional(String.t()) => String.t() | nil}, String.t()) :: String.t()
  defp build_invoke(attrs, inner) do
    case Map.get(attrs, "method") do
      nil ->
        ""

      method ->
        call =
          "#{invoke_target(Map.get(attrs, "component"))}#{method}(#{invoke_args(attrs, inner)})"

        case Map.get(attrs, "returnvariable") do
          nil -> "#{call};\n"
          ret -> "#{ret} = #{call};\n"
        end
    end
  end

  # `component="cfc.x"` (a path) instantiates: `new cfc.x().`; an expression
  # (`component="#obj#"`) calls on that instance: `obj.`; absent calls a sibling.
  @spec invoke_target(String.t() | nil) :: String.t()
  defp invoke_target(nil), do: ""

  defp invoke_target(component) do
    trimmed = String.trim(component)

    if String.starts_with?(trimmed, "#"),
      do: "#{strip_hashes(trimmed)}.",
      else: "new #{trimmed}()."
  end

  # Build the argument list from `<cfinvokeargument>` children, prefixed by an
  # `argumentCollection` if the tag carries one.
  @spec invoke_args(%{optional(String.t()) => String.t() | nil}, String.t()) :: String.t()
  defp invoke_args(attrs, inner) do
    collection =
      case Map.get(attrs, "argumentcollection") do
        nil -> []
        value -> ["argumentCollection = #{attr_expr(value)}"]
      end

    children =
      @cfinvokearg_re
      |> Regex.scan(inner)
      |> Enum.map(fn [_whole, arg_attrs] ->
        a = attrs_map(arg_attrs)
        "#{Map.fetch!(a, "name")} = #{attr_expr(Map.get(a, "value", ""))}"
      end)

    Enum.join(collection ++ children, ", ")
  end

  ## <cfthrow> / <cfparam>

  @spec convert_cfthrow(String.t()) :: String.t()
  defp convert_cfthrow(attrs_str) do
    attrs = attrs_map(attrs_str)

    args =
      ~w(message type detail)
      |> Enum.flat_map(fn key ->
        case Map.get(attrs, key) do
          nil -> []
          value -> ["#{key} = #{quoted(value)}"]
        end
      end)
      |> Enum.join(", ")

    "throw(#{args});"
  end

  # `<cfparam name="x" default="d">` ensures `x` is defined: assign the default
  # only when it is currently null/undefined (the elvis left side is null-safe).
  @spec convert_cfparam(String.t()) :: String.t()
  defp convert_cfparam(attrs_str) do
    attrs = attrs_map(attrs_str)

    case Map.get(attrs, "name") do
      nil ->
        ""

      name ->
        default = attrs |> Map.get("default") |> blank_to_empty_quoted()
        "#{name} = #{name} ?: #{default};"
    end
  end

  ## Switch / loop (shared with the original conversion)

  @spec convert_switch_tags(String.t()) :: String.t()
  defp convert_switch_tags(body) do
    body
    |> sub(@cfswitch_re, fn _whole, attrs ->
      expr = attrs_map(attrs) |> Map.get("expression", "") |> strip_hashes()
      "switch (#{expr}) {"
    end)
    |> sub(@cfcase_re, fn _whole, attrs ->
      value = attrs_map(attrs) |> Map.get("value", "")
      "case #{literal(value)}: "
    end)
    |> strip_to(~r/<\/cfcase\s*>/i, " break; ")
    |> strip_to(~r/<cfdefaultcase\s*>/i, "default: ")
    |> strip_to(~r/<\/cfdefaultcase\s*>/i, " break; ")
    |> strip_to(~r/<\/cfswitch\s*>/i, "}")
  end

  @spec convert_loop_tags(String.t()) :: String.t()
  defp convert_loop_tags(body) do
    body
    |> sub(@cfloop_re, fn _whole, attrs -> convert_cfloop_open(attrs_map(attrs)) end)
    |> strip_to(~r/<\/cfloop\s*>/i, "}")
  end

  @spec convert_cfloop_open(%{optional(String.t()) => String.t() | nil}) :: String.t()
  defp convert_cfloop_open(attrs) do
    cond do
      Map.has_key?(attrs, "from") and Map.has_key?(attrs, "to") ->
        index = strip_hashes(Map.fetch!(attrs, "index"))
        from = strip_hashes(Map.fetch!(attrs, "from"))
        to = strip_hashes(Map.fetch!(attrs, "to"))

        increment =
          case Map.get(attrs, "step") do
            nil -> "#{index}++"
            step -> "#{index} += #{strip_hashes(step)}"
          end

        "for (#{index} = #{from}; #{index} <= #{to}; #{increment}) {"

      Map.has_key?(attrs, "list") ->
        # The loop variable is `index` (classic) or `item` (modern); for-in binds
        # a bare name, so drop any scope prefix.
        index =
          (Map.get(attrs, "index") || Map.get(attrs, "item")) |> strip_hashes() |> bare_name()

        list = strip_hashes(Map.fetch!(attrs, "list"))

        collection =
          case Map.get(attrs, "delimiters") do
            nil -> "listToArray(#{list})"
            delims -> ~s|listToArray(#{list}, "#{delims}")|
          end

        "for (#{index} in #{collection}) {"

      Map.has_key?(attrs, "array") ->
        index =
          (Map.get(attrs, "index") || Map.get(attrs, "item")) |> strip_hashes() |> bare_name()

        "for (#{index} in #{strip_hashes(Map.fetch!(attrs, "array"))}) {"

      true ->
        # Unsupported form (query/collection/condition): leave a marker so the
        # function is dropped.
        "<cfloop>"
    end
  end

  ## Helpers

  @spec sub(String.t(), Regex.t(), (String.t(), String.t() -> String.t())) :: String.t()
  defp sub(source, regex, fun), do: Regex.replace(regex, source, fun)

  @spec strip(String.t(), Regex.t()) :: String.t()
  defp strip(source, regex), do: Regex.replace(regex, source, "")

  @spec strip_to(String.t(), Regex.t(), String.t()) :: String.t()
  defp strip_to(source, regex, replacement), do: Regex.replace(regex, source, replacement)

  @spec unquote_attr(String.t()) :: String.t()
  defp unquote_attr(<<?", _rest::binary>> = value),
    do: value |> String.slice(1..-2//1) |> String.replace(~s(""), ~s("))

  defp unquote_attr(<<?', _rest::binary>> = value),
    do: value |> String.slice(1..-2//1) |> String.replace("''", "'")

  defp unquote_attr(value), do: value

  # Render text as a cfscript double-quoted string: escape embedded quotes
  # (CFML doubles them), leaving `#...#` interpolation intact.
  @spec quoted(String.t()) :: String.t()
  defp quoted(text), do: ~s("#{String.replace(text, ~s("), ~s(""))}")

  # Render an attribute value as a cfscript literal: numbers/booleans bare,
  # everything else a double-quoted string.
  @spec literal(String.t()) :: String.t()
  defp literal(value) do
    cond do
      Regex.match?(~r/^-?\d+(\.\d+)?$/, value) -> value
      String.downcase(value) in ["true", "false"] -> String.downcase(value)
      true -> quoted(value)
    end
  end

  @spec blank_to_empty_quoted(String.t() | nil) :: String.t()
  defp blank_to_empty_quoted(nil), do: ~s("")
  defp blank_to_empty_quoted(value), do: literal(value)

  @spec catch_type(String.t() | nil) :: String.t()
  defp catch_type(nil), do: "any"
  defp catch_type(""), do: "any"
  defp catch_type(type), do: type

  @spec truthy_attr?(String.t() | nil) :: boolean()
  defp truthy_attr?(nil), do: false
  defp truthy_attr?(value), do: String.downcase(value) in ["true", "yes"]

  @spec strip_hashes(String.t()) :: String.t()
  defp strip_hashes(value),
    do: value |> String.trim() |> String.trim_leading("#") |> String.trim_trailing("#")

  # An attribute value as a cfscript expression: a fully `#...#`-wrapped value is
  # the bare expression; anything else is a (possibly interpolated) literal.
  @spec attr_expr(String.t()) :: String.t()
  defp attr_expr(value) do
    trimmed = String.trim(value)

    if String.match?(trimmed, ~r/^#[^#]*#$/),
      do: strip_hashes(trimmed),
      else: literal(value)
  end

  # The last dotted segment of a (possibly scope-qualified) name: `local.n` -> `n`.
  @spec bare_name(String.t()) :: String.t()
  defp bare_name(name), do: name |> String.split(".") |> List.last()
end
