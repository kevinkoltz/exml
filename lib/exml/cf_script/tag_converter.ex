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
  @cfobject_re Regex.compile!("<cfobject\\b(#{@tag_content})\\s*/?>", "i")

  # Any CFML tag the conversions above didn't handle (cfmodule, cffile, cfhttp,
  # cfthread, cfobject, ...). The open tag becomes a marker that raises if
  # reached; the close tag is blanked. Per statement, so the rest of the
  # function still loads and runs.
  @unsupported_open Regex.compile!("<cf(\\w+)\\b(#{@tag_content})/?>", "i")
  @unsupported_close Regex.compile!("</cf\\w+\\s*>", "i")

  # Attributes with no runtime effect for us — always allowed (ignored).
  @cosmetic ~w(hint output access displayname description)

  # Recognized attributes per tag. An attribute outside this set (plus cosmetic)
  # is flagged as unsupported, so a typo or an unimplemented option surfaces as a
  # loud error rather than being silently ignored.
  @allowed_attrs %{
    "cffunction" => ~w(name returntype localmode static abstract final roles modifier),
    "cfquery" =>
      ~w(name datasource dbtype result maxrows timeout blockfactor cachedwithin cachedafter username password),
    "cfloop" =>
      ~w(from to index step list array item query collection condition times delimiters group startrow endrow),
    "cfthrow" => ~w(message type detail errorcode extendedinfo object),
    "cfinvoke" => ~w(component method returnvariable argumentcollection),
    "cfsavecontent" => ~w(variable trim)
  }

  ## Public API

  @doc "Rewrite every `<cffunction>...</cffunction>` in `source` to cfscript."
  @spec convert_cffunctions(String.t()) :: String.t()
  def convert_cffunctions(source) do
    Regex.replace(@cffunction_re, source, fn whole, attrs, inner ->
      convert_one_function(attrs, inner, whole)
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

  @spec convert_one_function(String.t(), String.t(), String.t()) :: String.t()
  defp convert_one_function(attrs_str, inner, whole) do
    attrs = attrs_map(attrs_str)

    case Map.get(attrs, "name") do
      nil ->
        blank_lines(whole)

      name ->
        {params, body} = extract_arguments(inner)
        converted = convert_body(body)
        signature = "function #{name}(#{params}) #{function_suffix(attrs)}"

        cond do
          # An unrecognized `<cffunction>` attribute (typo / unimplemented option).
          bad = unknown_attr("cffunction", attrs) ->
            marker = ~s|__exml_unsupported("function [#{name}]: unsupported attribute [#{bad}]");|
            "#{signature}{ #{marker}#{blank_lines(converted)} }"

          # An unconverted `<cf...>` tag remains: don't silently drop the function
          # — load it with a marker body that raises (naming the tag) if called.
          tag = leftover_cf_tag(converted) ->
            marker =
              ~s|__exml_unsupported("function [#{name}] uses unsupported CFML tag #{tag}");|

            assertive = "#{signature}{ #{marker}#{blank_lines(converted)} }"
            if lexes?(assertive), do: assertive, else: blank_lines(whole)

          # Line-neutral: signature on the `<cffunction>` line, `}` on the
          # `</cffunction>` line, body newlines preserved — so statement line
          # numbers map back to the original `.cfc`.
          true ->
            source = "#{signature}{#{converted}}"
            if lexes?(source), do: source, else: blank_lines(whole)
        end
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

  # The first attribute on `tag` that we don't recognize, or nil. Used to flag a
  # typo / unimplemented option assertively.
  @spec unknown_attr(String.t(), %{optional(String.t()) => String.t() | nil}) :: String.t() | nil
  defp unknown_attr(tag, attrs) do
    allowed = Map.get(@allowed_attrs, tag, []) ++ @cosmetic
    attrs |> Map.keys() |> Enum.find(&(&1 not in allowed))
  end

  # A statement that raises a clear "unsupported attribute" error if reached.
  # Marker text avoids literal `<cf...>` so it isn't re-detected as a leftover tag.
  @spec unsupported_stmt(String.t(), String.t()) :: String.t()
  defp unsupported_stmt(tag, attr),
    do: ~s|__exml_unsupported("#{tag}: unsupported attribute [#{attr}]");|

  # The name of the first unconverted `<cf...>` tag still in the body, or nil.
  @spec leftover_cf_tag(String.t()) :: String.t() | nil
  defp leftover_cf_tag(body) do
    case Regex.run(~r/<\s*\/?\s*(cf\w*)/i, body, capture: :all_but_first) do
      [tag] -> String.downcase(tag)
      nil -> nil
    end
  end

  # Whether `source` lexes cleanly (a function whose tokens can't be lexed — e.g.
  # an unbalanced quote — is dropped rather than corrupting sibling functions,
  # since the whole component is lexed in one pass).
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
    |> blank(@cfmail_re)
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
    |> sub(@cfobject_re, fn _whole, attrs -> convert_cfobject(attrs) end)
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
    |> markerize_unsupported_tags()
  end

  # Replace any leftover (unsupported) CFML tag with a per-statement marker, so a
  # function using e.g. `<cfmodule>` or `<cffile>` still loads and only raises at
  # that line if reached.
  @spec markerize_unsupported_tags(String.t()) :: String.t()
  defp markerize_unsupported_tags(body) do
    body
    |> sub(@unsupported_open, fn whole, tag, _attrs ->
      pad_to(~s|__exml_unsupported("unsupported CFML tag cf#{String.downcase(tag)}");|, whole)
    end)
    |> blank(@unsupported_close)
  end

  ## <cfquery> -> queryExecute

  @spec convert_cfquery(String.t()) :: String.t()
  defp convert_cfquery(body) do
    Regex.replace(@cfquery_re, body, fn whole, attrs, sql ->
      attr_map = attrs_map(attrs)

      statement =
        case unknown_attr("cfquery", attr_map) do
          nil ->
            {converted_sql, params} = convert_queryparams(sql)
            call = "queryExecute(#{quoted(converted_sql)}, {#{params}})"

            case Map.get(attr_map, "name") do
              nil -> "#{call};"
              name -> "#{name} = #{call};"
            end

          bad ->
            unsupported_stmt("cfquery", bad)
        end

      pad_to(statement, whole)
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
    Regex.replace(@cfsavecontent_re, body, fn whole, attrs, content ->
      attr_map = attrs_map(attrs)

      statement =
        case unknown_attr("cfsavecontent", attr_map) do
          nil ->
            case Map.get(attr_map, "variable") do
              nil -> ""
              var -> "#{var} = #{quoted(content)};"
            end

          bad ->
            unsupported_stmt("cfsavecontent", bad)
        end

      pad_to(statement, whole)
    end)
  end

  ## <cfinvoke> -> method call

  @spec convert_cfinvoke(String.t()) :: String.t()
  defp convert_cfinvoke(body) do
    body
    |> sub(@cfinvoke_re, fn whole, attrs, inner ->
      pad_to(build_invoke(attrs_map(attrs), inner), whole)
    end)
    |> sub(@cfinvoke_self_re, fn _whole, attrs -> build_invoke(attrs_map(attrs), "") end)
  end

  @spec build_invoke(%{optional(String.t()) => String.t() | nil}, String.t()) :: String.t()
  defp build_invoke(attrs, inner) do
    cond do
      bad = unknown_attr("cfinvoke", attrs) ->
        unsupported_stmt("cfinvoke", bad)

      method = Map.get(attrs, "method") ->
        call =
          "#{invoke_target(Map.get(attrs, "component"))}#{method}(#{invoke_args(attrs, inner)})"

        case Map.get(attrs, "returnvariable") do
          nil -> "#{call};"
          ret -> "#{ret} = #{call};"
        end

      true ->
        ""
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

  ## <cfobject> -> new

  # `<cfobject component="X" name="n">` instantiates a component into `n`. Other
  # object types (java/com/...) aren't modelled, so they become a marker.
  @spec convert_cfobject(String.t()) :: String.t()
  defp convert_cfobject(attrs_str) do
    attrs = attrs_map(attrs_str)
    type = (Map.get(attrs, "type") || "component") |> String.downcase()
    component = Map.get(attrs, "component")
    name = Map.get(attrs, "name")

    cond do
      type == "component" and is_binary(component) and is_binary(name) ->
        "#{name} = new #{component}();"

      true ->
        unsupported_stmt("cfobject", "type=#{type}")
    end
  end

  ## <cfthrow> / <cfparam>

  @spec convert_cfthrow(String.t()) :: String.t()
  defp convert_cfthrow(attrs_str) do
    attrs = attrs_map(attrs_str)

    case unknown_attr("cfthrow", attrs) do
      nil ->
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

      bad ->
        unsupported_stmt("cfthrow", bad)
    end
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
      bad = unknown_attr("cfloop", attrs) ->
        "#{unsupported_stmt("cfloop", bad)} while (false) {"

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

      # `collection` iterates a struct's keys.
      Map.has_key?(attrs, "collection") ->
        index =
          (Map.get(attrs, "item") || Map.get(attrs, "index")) |> strip_hashes() |> bare_name()

        "for (#{index} in #{strip_hashes(Map.fetch!(attrs, "collection"))}) {"

      # `condition` is a plain while loop.
      Map.has_key?(attrs, "condition") ->
        "while (#{strip_hashes(Map.fetch!(attrs, "condition"))}) {"

      true ->
        # Unsupported form (e.g. `query=` with its current-row semantics): a
        # marker that raises if reached, plus a dead `while (false)` so the
        # `</cfloop>` -> `}` stays balanced and the rest of the function loads.
        ~s|__exml_unsupported("unsupported cfloop form"); while (false) {|
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

  # Replace a dropped block with just its newlines, so surrounding line numbers
  # don't shift.
  @spec blank_lines(String.t()) :: String.t()
  defp blank_lines(text), do: String.duplicate("\n", nl_count(text))

  @spec nl_count(String.t()) :: non_neg_integer()
  defp nl_count(text), do: text |> :binary.matches("\n") |> length()

  # Replace each match with only its newlines (line-preserving deletion).
  @spec blank(String.t(), Regex.t()) :: String.t()
  defp blank(source, regex), do: Regex.replace(regex, source, &blank_lines/1)

  # Pad a single-statement replacement with trailing newlines so it spans the
  # same number of lines as the multi-line block it replaces.
  @spec pad_to(String.t(), String.t()) :: String.t()
  defp pad_to(replacement, original) do
    replacement <> String.duplicate("\n", max(nl_count(original) - nl_count(replacement), 0))
  end

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
