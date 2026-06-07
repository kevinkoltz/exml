defmodule ExML.CFScript.Parser do
  @moduledoc """
  Recursive-descent parser for cfscript, producing an `ExML.CFScript.AST`.

  ## Expression representation

  Expressions are tagged tuples:

    * `{:lit, value}` — number / string / boolean literal
    * `{:var, name}` — bare identifier reference
    * `{:member, obj, name}` — `obj.name`
    * `{:static_member, obj, name}` — `obj::name`
    * `{:index, obj, key}` — `obj[key]`
    * `{:call, callee, args}` — `callee(args...)`
    * `{:new, "cfc.foo", args}` — `new cfc.foo(args...)`
    * `{:binop, op, left, right}` — `op` is a lowercase string ("&", "==", "and", ...)
    * `{:unop, op, operand}` — `op` is `"not"` or `"-"`
    * `{:fun, params, body}` — anonymous `function(params) { body }`

  ## Statement representation

    * `{:if, cond, then_stmts, else_stmts}` (`else_stmts` is `[]` when absent)
    * `{:return, expr_or_nil}`
    * `{:var, name, expr}` — `var name = expr`
    * `{:assign, target_expr, expr}`
    * `{:expr, expr}`

  Operator precedence, low → high: `or`, `and`, `not` (unary), comparison,
  `&` (concat), `+`/`-`, `*`/`/`/`mod`, unary `-`, postfix (`.`/`::`/call/index).
  """

  alias ExML.CFScript.{AST, Lexer}

  @access_modifiers ~w(public private package remote)

  @doc "Parse a full cfscript component source string into an `AST.Component`."
  @spec parse_component(binary()) :: AST.Component.t()
  def parse_component(source) when is_binary(source) do
    source |> Lexer.tokenize() |> do_parse_component()
  end

  @doc "Parse a bare expression string (used in tests)."
  @spec parse_expression(binary()) :: tuple()
  def parse_expression(source) when is_binary(source) do
    {expr, _rest} = source |> Lexer.tokenize() |> parse_expr()
    expr
  end

  @doc """
  Parse a single function declaration from a token list.

  Used by `ExML.CFScript.Loader` for lenient, function-by-function loading so
  one unsupported sibling function doesn't sink the whole component.
  """
  @spec parse_one_function([Lexer.token()]) :: AST.Function.t()
  def parse_one_function(tokens) do
    {func, _rest} = parse_function_decl(tokens)
    func
  end

  @doc "Parse a list of statements from tokens (e.g. a `static {...}` block body)."
  @spec parse_statements_from_tokens([Lexer.token()]) :: [tuple()]
  def parse_statements_from_tokens(tokens) do
    {stmts, _rest} = parse_statements(tokens, [])
    stmts
  end

  ## Component / function declarations

  @spec do_parse_component([Lexer.token()]) :: AST.Component.t()
  defp do_parse_component(tokens) do
    case tokens do
      [{:ident, kw} | rest] ->
        if kw?(kw, "component") do
          {extends, rest} = parse_component_attrs(rest, nil)
          rest = expect_op(rest, "{")
          {functions, rest} = parse_members(rest, [])
          _ = expect_op(rest, "}")
          %AST.Component{functions: functions, extends: extends}
        else
          {functions, _rest} = parse_members(tokens, [])
          %AST.Component{functions: functions}
        end

      _ ->
        {functions, _rest} = parse_members(tokens, [])
        %AST.Component{functions: functions}
    end
  end

  # Component attributes: `extends="..." output="false"` etc, until `{`.
  @spec parse_component_attrs([Lexer.token()], String.t() | nil) ::
          {String.t() | nil, [Lexer.token()]}
  defp parse_component_attrs([{:op, "{"} | _] = tokens, extends), do: {extends, tokens}

  defp parse_component_attrs([{:ident, name}, {:op, "="}, {:string, val} | rest], extends) do
    extends = if kw?(name, "extends"), do: val, else: extends
    parse_component_attrs(rest, extends)
  end

  defp parse_component_attrs([{:ident, _name}, {:op, "="}, {:ident, _val} | rest], extends) do
    parse_component_attrs(rest, extends)
  end

  defp parse_component_attrs(tokens, extends), do: {extends, tokens}

  # Parse zero or more member function declarations until `}` or EOF.
  @spec parse_members([Lexer.token()], [AST.Function.t()]) ::
          {[AST.Function.t()], [Lexer.token()]}
  defp parse_members([], acc), do: {Enum.reverse(acc), []}
  defp parse_members([{:op, "}"} | _] = tokens, acc), do: {Enum.reverse(acc), tokens}

  defp parse_members(tokens, acc) do
    {func, rest} = parse_function_decl(tokens)
    parse_members(rest, [func | acc])
  end

  # Read leading modifiers/return-type, then a `function` declaration.
  @spec parse_function_decl([Lexer.token()]) :: {AST.Function.t(), [Lexer.token()]}
  defp parse_function_decl(tokens) do
    {static, return_type, tokens} = parse_function_prefix(tokens, false, nil)
    tokens = expect_ident(tokens, "function")
    {name, tokens} = take_ident(tokens)
    tokens = expect_op(tokens, "(")
    {params, tokens} = parse_params(tokens, [])
    tokens = expect_op(tokens, ")")
    {localmode, tokens} = parse_function_attrs(tokens, false)
    tokens = expect_op(tokens, "{")
    {body, tokens} = parse_statements(tokens, [])
    tokens = expect_op(tokens, "}")

    {%AST.Function{
       name: name,
       params: params,
       static: static,
       localmode: localmode,
       return_type: return_type,
       body: body
     }, tokens}
  end

  @spec parse_function_prefix([Lexer.token()], boolean(), String.t() | nil) ::
          {boolean(), String.t() | nil, [Lexer.token()]}
  defp parse_function_prefix([{:ident, word} | rest] = tokens, static, return_type) do
    down = String.downcase(word)

    cond do
      down == "function" -> {static, return_type, tokens}
      down == "static" -> parse_function_prefix(rest, true, return_type)
      down in @access_modifiers -> parse_function_prefix(rest, static, return_type)
      true -> parse_function_prefix(rest, static, word)
    end
  end

  # Function attributes after `)`: `localmode=true`, `hint="..."`, etc., until
  # `{`. Captures whether localmode is enabled (`true` or `'modern'`), which
  # decides where unscoped assignments land at runtime.
  @spec parse_function_attrs([Lexer.token()], boolean()) :: {boolean(), [Lexer.token()]}
  defp parse_function_attrs([{:op, "{"} | _] = tokens, localmode), do: {localmode, tokens}

  defp parse_function_attrs([{:ident, name}, {:op, "="}, {kind, v} | rest], localmode)
       when kind in [:string, :ident, :int] do
    localmode = if kw?(name, "localmode"), do: localmode_value(v), else: localmode
    parse_function_attrs(rest, localmode)
  end

  defp parse_function_attrs(tokens, localmode), do: {localmode, tokens}

  @spec localmode_value(any()) :: boolean()
  defp localmode_value(v) when is_binary(v), do: String.downcase(v) in ["true", "modern"]
  defp localmode_value(_), do: true

  @spec skip_function_attrs([Lexer.token()]) :: [Lexer.token()]
  defp skip_function_attrs(tokens) do
    {_localmode, rest} = parse_function_attrs(tokens, false)
    rest
  end

  ## Parameters

  @spec parse_params([Lexer.token()], [AST.Param.t()]) :: {[AST.Param.t()], [Lexer.token()]}
  defp parse_params([{:op, ")"} | _] = tokens, acc), do: {Enum.reverse(acc), tokens}

  defp parse_params(tokens, acc) do
    {param, tokens} = parse_param(tokens)

    case tokens do
      [{:op, ","} | rest] -> parse_params(rest, [param | acc])
      _ -> {Enum.reverse([param | acc]), tokens}
    end
  end

  # `[required] [type] name [= default]`
  @spec parse_param([Lexer.token()]) :: {AST.Param.t(), [Lexer.token()]}
  defp parse_param(tokens) do
    {required, tokens} =
      case tokens do
        [{:ident, w} | rest] -> if kw?(w, "required"), do: {true, rest}, else: {false, tokens}
        _ -> {false, tokens}
      end

    {idents, tokens} = take_leading_idents(tokens, [])

    {type, name} =
      case idents do
        [name] -> {nil, name}
        [type, name] -> {type, name}
        _ -> raise "ExML.CFScript.Parser: malformed parameter near #{inspect(tokens)}"
      end

    {default, tokens} =
      case tokens do
        [{:op, "="} | rest] ->
          {expr, rest} = parse_expr(rest)
          {expr, rest}

        _ ->
          {nil, tokens}
      end

    {%AST.Param{name: name, type: type, required: required, default: default}, tokens}
  end

  # Collect consecutive identifiers (param type + name) stopping at `,`/`)`/`=`.
  @spec take_leading_idents([Lexer.token()], [String.t()]) :: {[String.t()], [Lexer.token()]}
  defp take_leading_idents([{:ident, w}, {:op, op} | _] = tokens, acc)
       when op in ["=", ",", ")"] do
    {Enum.reverse([w | acc]), tl(tokens)}
  end

  defp take_leading_idents([{:ident, w} | rest], acc), do: take_leading_idents(rest, [w | acc])
  defp take_leading_idents(tokens, acc), do: {Enum.reverse(acc), tokens}

  ## Statements

  @spec parse_statements([Lexer.token()], [tuple()]) :: {[tuple()], [Lexer.token()]}
  defp parse_statements([{:op, "}"} | _] = tokens, acc), do: {Enum.reverse(acc), tokens}
  defp parse_statements([], acc), do: {Enum.reverse(acc), []}

  defp parse_statements([{:op, ";"} | rest], acc), do: parse_statements(rest, acc)

  defp parse_statements(tokens, acc) do
    {stmt, rest} = parse_statement(tokens)
    parse_statements(rest, [stmt | acc])
  end

  @spec parse_statement([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_statement([{:ident, w} | rest] = tokens) do
    cond do
      kw?(w, "if") -> parse_if(rest)
      kw?(w, "return") -> parse_return(rest)
      kw?(w, "var") -> parse_var(rest)
      kw?(w, "for") -> parse_for(rest)
      kw?(w, "while") -> parse_while(rest)
      kw?(w, "try") -> parse_try(rest)
      true -> parse_expr_statement(tokens)
    end
  end

  defp parse_statement(tokens), do: parse_expr_statement(tokens)

  @spec parse_if([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_if(tokens) do
    tokens = expect_op(tokens, "(")
    {cond_expr, tokens} = parse_expr(tokens)
    tokens = expect_op(tokens, ")")
    {then_stmts, tokens} = parse_block_or_statement(tokens)

    case tokens do
      [{:ident, w} | rest] ->
        if kw?(w, "else") do
          {else_stmts, rest} = parse_block_or_statement(rest)
          {{:if, cond_expr, then_stmts, else_stmts}, rest}
        else
          {{:if, cond_expr, then_stmts, []}, tokens}
        end

      _ ->
        {{:if, cond_expr, then_stmts, []}, tokens}
    end
  end

  @spec parse_block_or_statement([Lexer.token()]) :: {[tuple()], [Lexer.token()]}
  defp parse_block_or_statement([{:op, "{"} | rest]) do
    {stmts, rest} = parse_statements(rest, [])
    {stmts, expect_op(rest, "}")}
  end

  defp parse_block_or_statement(tokens) do
    {stmt, rest} = parse_statement(tokens)
    {[stmt], rest}
  end

  @spec parse_return([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_return([{:op, ";"} | rest]), do: {{:return, nil}, rest}
  defp parse_return([{:op, "}"} | _] = tokens), do: {{:return, nil}, tokens}

  defp parse_return(tokens) do
    {expr, rest} = parse_expr(tokens)
    {{:return, expr}, drop_semicolon(rest)}
  end

  @spec parse_var([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_var(tokens) do
    {name, tokens} = take_ident(tokens)

    case tokens do
      [{:op, "="} | rest] ->
        {expr, rest} = parse_expr(rest)
        {{:var, name, expr}, drop_semicolon(rest)}

      _ ->
        {{:var, name, {:lit, nil}}, drop_semicolon(tokens)}
    end
  end

  @spec parse_expr_statement([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_expr_statement(tokens) do
    {stmt, rest} = parse_simple_statement(tokens)
    {stmt, drop_semicolon(rest)}
  end

  # An assignment, compound assignment (`+=`/`&=`/...), increment (`x++`/`x--`),
  # or bare expression — without consuming a trailing `;`. Reused by for-loop
  # init/increment clauses.
  @compound_ops %{"+=" => "+", "-=" => "-", "*=" => "*", "/=" => "/", "&=" => "&"}
  @spec parse_simple_statement([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_simple_statement(tokens) do
    {target, rest} = parse_expr(tokens)

    case rest do
      [{:op, "="} | rest] ->
        {rhs, rest} = parse_expr(rest)
        {{:assign, target, rhs}, rest}

      [{:op, op} | rest] when is_map_key(@compound_ops, op) ->
        {rhs, rest} = parse_expr(rest)
        {{:assign, target, {:binop, Map.fetch!(@compound_ops, op), target, rhs}}, rest}

      [{:op, op} | rest] when op in ["++", "--"] ->
        {{:incr, target, String.first(op)}, rest}

      _ ->
        {{:expr, target}, rest}
    end
  end

  # `for (...)` — either C-style (init; cond; incr) or for-in (item in coll).
  @spec parse_for([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_for(tokens) do
    tokens = expect_op(tokens, "(")

    if for_in?(tokens) do
      parse_for_in(tokens)
    else
      parse_for_c_style(tokens)
    end
  end

  # for-in shape: `[var] ident in <expr>` — detect `in` before the first `;`.
  @spec for_in?([Lexer.token()]) :: boolean()
  defp for_in?(tokens) do
    tokens
    |> Enum.take_while(fn
      {:op, ";"} -> false
      {:op, ")"} -> false
      _ -> true
    end)
    |> Enum.any?(fn {type, val} -> type == :ident and String.downcase(val) == "in" end)
  end

  @spec parse_for_in([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_for_in(tokens) do
    tokens = drop_var(tokens)
    {name, tokens} = take_ident(tokens)
    tokens = expect_ident(tokens, "in")
    {coll, tokens} = parse_expr(tokens)
    tokens = expect_op(tokens, ")")
    {body, tokens} = parse_block_or_statement(tokens)
    {{:for_in, name, coll, body}, tokens}
  end

  @spec parse_for_c_style([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_for_c_style(tokens) do
    {init, tokens} = parse_for_init(tokens)
    tokens = expect_op(tokens, ";")
    {cond_expr, tokens} = parse_expr(tokens)
    tokens = expect_op(tokens, ";")
    {incr, tokens} = parse_simple_statement(tokens)
    tokens = expect_op(tokens, ")")
    {body, tokens} = parse_block_or_statement(tokens)
    {{:for, init, cond_expr, incr, body}, tokens}
  end

  # The init clause may be a `var` declaration or a simple statement.
  @spec parse_for_init([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_for_init([{:ident, w} | rest] = tokens) do
    if kw?(w, "var"), do: parse_var_no_semicolon(rest), else: parse_simple_statement(tokens)
  end

  defp parse_for_init(tokens), do: parse_simple_statement(tokens)

  @spec parse_var_no_semicolon([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_var_no_semicolon(tokens) do
    {name, tokens} = take_ident(tokens)
    tokens = expect_op(tokens, "=")
    {expr, tokens} = parse_expr(tokens)
    {{:var, name, expr}, tokens}
  end

  @spec drop_var([Lexer.token()]) :: [Lexer.token()]
  defp drop_var([{:ident, w} | rest]) do
    if kw?(w, "var"), do: rest, else: [{:ident, w} | rest]
  end

  defp drop_var(tokens), do: tokens

  @spec parse_while([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_while(tokens) do
    tokens = expect_op(tokens, "(")
    {cond_expr, tokens} = parse_expr(tokens)
    tokens = expect_op(tokens, ")")
    {body, tokens} = parse_block_or_statement(tokens)
    {{:while, cond_expr, body}, tokens}
  end

  # try { ... } catch (Type e) { ... } ... [finally { ... }]
  @spec parse_try([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_try(tokens) do
    tokens = expect_op(tokens, "{")
    {body, tokens} = parse_statements(tokens, [])
    tokens = expect_op(tokens, "}")
    {catches, tokens} = parse_catches(tokens, [])
    {finally, tokens} = parse_finally(tokens)
    {{:try, body, catches, finally}, tokens}
  end

  @spec parse_catches([Lexer.token()], [tuple()]) :: {[tuple()], [Lexer.token()]}
  defp parse_catches([{:ident, w} | rest] = tokens, acc) do
    if kw?(w, "catch") do
      rest = expect_op(rest, "(")
      {type, var, rest} = parse_catch_header(rest)
      rest = expect_op(rest, ")")
      rest = expect_op(rest, "{")
      {body, rest} = parse_statements(rest, [])
      rest = expect_op(rest, "}")
      parse_catches(rest, [{type, var, body} | acc])
    else
      {Enum.reverse(acc), tokens}
    end
  end

  defp parse_catches(tokens, acc), do: {Enum.reverse(acc), tokens}

  # `(Type var)` or `(var)` (type defaults to "any"). Type may be dotted.
  @spec parse_catch_header([Lexer.token()]) :: {String.t(), String.t(), [Lexer.token()]}
  defp parse_catch_header(tokens) do
    {parts, rest} = read_catch_parts(tokens, [])

    case parts do
      [var] -> {"any", var, rest}
      parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts), rest}
    end
  end

  defp read_catch_parts([{:op, ")"} | _] = tokens, acc), do: {Enum.reverse(acc), tokens}
  defp read_catch_parts([{:ident, w} | rest], acc), do: read_catch_parts(rest, [w | acc])
  defp read_catch_parts([{:string, s} | rest], acc), do: read_catch_parts(rest, [s | acc])
  defp read_catch_parts([{:op, "."} | rest], acc), do: read_catch_parts(rest, acc)

  @spec parse_finally([Lexer.token()]) :: {[tuple()], [Lexer.token()]}
  defp parse_finally([{:ident, w} | rest]) do
    if kw?(w, "finally") do
      rest = expect_op(rest, "{")
      {body, rest} = parse_statements(rest, [])
      {body, expect_op(rest, "}")}
    else
      {[], [{:ident, w} | rest]}
    end
  end

  defp parse_finally(tokens), do: {[], tokens}

  ## Expressions (precedence climbing)

  @spec parse_expr([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  def parse_expr(tokens), do: parse_or(tokens)

  defp parse_or(tokens), do: parse_binop_level(tokens, &parse_and/1, [{"or", "or"}, {"||", "or"}])

  defp parse_and(tokens),
    do: parse_binop_level(tokens, &parse_not/1, [{"and", "and"}, {"&&", "and"}])

  defp parse_not([{:ident, w} | rest]) do
    if kw?(w, "not") do
      {operand, rest} = parse_not(rest)
      {{:unop, "not", operand}, rest}
    else
      parse_comparison([{:ident, w} | rest])
    end
  end

  defp parse_not([{:op, "!"} | rest]) do
    {operand, rest} = parse_not(rest)
    {{:unop, "not", operand}, rest}
  end

  defp parse_not(tokens), do: parse_comparison(tokens)

  @comparisons [
    {"==", "=="},
    {"!=", "!="},
    {"<=", "<="},
    {">=", ">="},
    {"<>", "!="},
    {"<", "<"},
    {">", ">"},
    {"eq", "=="},
    {"neq", "!="},
    {"ne", "!="},
    {"lt", "<"},
    {"gt", ">"},
    {"lte", "<="},
    {"gte", ">="},
    {"le", "<="},
    {"ge", ">="},
    {"is", "=="}
  ]
  defp parse_comparison(tokens), do: parse_binop_level(tokens, &parse_concat/1, @comparisons)

  defp parse_concat(tokens), do: parse_binop_level(tokens, &parse_additive/1, [{"&", "&"}])

  defp parse_additive(tokens),
    do: parse_binop_level(tokens, &parse_mult/1, [{"+", "+"}, {"-", "-"}])

  defp parse_mult(tokens),
    do:
      parse_binop_level(tokens, &parse_unary/1, [{"*", "*"}, {"/", "/"}, {"%", "%"}, {"mod", "%"}])

  defp parse_unary([{:op, "-"} | rest]) do
    {operand, rest} = parse_unary(rest)
    {{:unop, "-", operand}, rest}
  end

  defp parse_unary(tokens), do: parse_postfix(tokens)

  # Generic left-associative binary operator level. `ops` is a list of
  # `{token_text, normalized_op}` pairs; token text matches case-insensitively
  # for word operators and exactly for symbolic ones.
  @spec parse_binop_level([Lexer.token()], (... -> any()), [{String.t(), String.t()}]) ::
          {tuple(), [Lexer.token()]}
  defp parse_binop_level(tokens, next, ops) do
    {left, rest} = next.(tokens)
    parse_binop_loop(left, rest, next, ops)
  end

  defp parse_binop_loop(left, tokens, next, ops) do
    case match_binop(tokens, ops) do
      {op, rest} ->
        {right, rest} = next.(rest)
        parse_binop_loop({:binop, op, left, right}, rest, next, ops)

      :nomatch ->
        {left, tokens}
    end
  end

  @spec match_binop([Lexer.token()], [{String.t(), String.t()}]) ::
          {String.t(), [Lexer.token()]} | :nomatch
  defp match_binop([{:op, sym} | rest], ops) do
    case List.keyfind(ops, sym, 0) do
      {_, normalized} -> {normalized, rest}
      nil -> :nomatch
    end
  end

  defp match_binop([{:ident, word} | rest], ops) do
    down = String.downcase(word)

    case Enum.find(ops, fn {text, _} -> text == down end) do
      {_, normalized} -> {normalized, rest}
      nil -> :nomatch
    end
  end

  defp match_binop(_tokens, _ops), do: :nomatch

  ## Postfix: member access, static access, calls, indexing

  @spec parse_postfix([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_postfix(tokens) do
    {primary, rest} = parse_primary(tokens)
    parse_postfix_loop(primary, rest)
  end

  defp parse_postfix_loop(expr, [{:op, "."}, {:ident, name} | rest]) do
    parse_postfix_loop({:member, expr, name}, rest)
  end

  defp parse_postfix_loop(expr, [{:op, "::"}, {:ident, name} | rest]) do
    parse_postfix_loop({:static_member, expr, name}, rest)
  end

  defp parse_postfix_loop(expr, [{:op, "("} | rest]) do
    {args, rest} = parse_args(rest, [])
    parse_postfix_loop({:call, expr, args}, rest)
  end

  defp parse_postfix_loop(expr, [{:op, "["} | rest]) do
    {key, rest} = parse_expr(rest)
    parse_postfix_loop({:index, expr, key}, expect_op(rest, "]"))
  end

  defp parse_postfix_loop(expr, tokens), do: {expr, tokens}

  @spec parse_args([Lexer.token()], [tuple()]) :: {[tuple()], [Lexer.token()]}
  defp parse_args([{:op, ")"} | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_args(tokens, acc) do
    {arg, rest} = parse_argument(tokens)

    case rest do
      [{:op, ","} | rest2] ->
        parse_args(rest2, [arg | acc])

      [{:op, ")"} | rest2] ->
        {Enum.reverse([arg | acc]), rest2}

      _ ->
        raise "ExML.CFScript.Parser: expected ',' or ')' in argument list near #{inspect(rest)}"
    end
  end

  # A named argument (`name = expr` / `name : expr`) becomes `{:named, name,
  # expr}`; otherwise a positional expression.
  defp parse_argument([{:ident, name}, {:op, op} | rest]) when op in ["=", ":"] do
    {expr, rest} = parse_expr(rest)
    {{:named, name, expr}, rest}
  end

  defp parse_argument(tokens), do: parse_expr(tokens)

  # Comma-separated expressions until `closer` (used for array literals).
  @spec parse_list_until([Lexer.token()], String.t(), [tuple()]) :: {[tuple()], [Lexer.token()]}
  defp parse_list_until([{:op, closer} | rest], closer, acc), do: {Enum.reverse(acc), rest}

  defp parse_list_until(tokens, closer, acc) do
    {expr, rest} = parse_expr(tokens)

    case rest do
      [{:op, ","} | rest2] ->
        parse_list_until(rest2, closer, [expr | acc])

      [{:op, ^closer} | rest2] ->
        {Enum.reverse([expr | acc]), rest2}

      _ ->
        raise "ExML.CFScript.Parser: expected ',' or '#{closer}' near #{inspect(Enum.take(rest, 3))}"
    end
  end

  # Struct literal pairs: `key (: | =) expr`, comma-separated, until `}`.
  @spec parse_struct_pairs([Lexer.token()], [{String.t(), tuple()}]) ::
          {[{String.t(), tuple()}], [Lexer.token()]}
  defp parse_struct_pairs([{:op, "}"} | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_struct_pairs(tokens, acc) do
    {key, tokens} = parse_struct_key(tokens)
    tokens = expect_struct_separator(tokens)
    {value, tokens} = parse_expr(tokens)
    acc = [{key, value} | acc]

    case tokens do
      [{:op, ","} | rest] ->
        parse_struct_pairs(rest, acc)

      [{:op, "}"} | rest] ->
        {Enum.reverse(acc), rest}

      _ ->
        raise "ExML.CFScript.Parser: expected ',' or '}' in struct near #{inspect(Enum.take(tokens, 3))}"
    end
  end

  @spec parse_struct_key([Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp parse_struct_key([{:ident, name} | rest]), do: {name, rest}
  defp parse_struct_key([{:string, s} | rest]), do: {s, rest}
  defp parse_struct_key([{:int, n} | rest]), do: {Integer.to_string(n), rest}

  defp parse_struct_key(tokens),
    do: raise("ExML.CFScript.Parser: invalid struct key near #{inspect(Enum.take(tokens, 3))}")

  @spec expect_struct_separator([Lexer.token()]) :: [Lexer.token()]
  defp expect_struct_separator([{:op, op} | rest]) when op in [":", "="], do: rest

  defp expect_struct_separator(tokens),
    do:
      raise(
        "ExML.CFScript.Parser: expected ':' or '=' in struct near #{inspect(Enum.take(tokens, 3))}"
      )

  ## String interpolation

  # CFML strings interpolate `#expr#` (both quote styles); `##` is a literal `#`.
  # A string with no interpolation stays a `{:lit, ...}`; otherwise it becomes a
  # `&`-concatenation (seeded with "" so the result is always a string).
  @spec interpolate(String.t()) :: tuple()
  defp interpolate(content) do
    case split_interp(content, "", []) do
      [] ->
        {:lit, ""}

      [{:lit, s}] ->
        {:lit, s}

      parts ->
        Enum.reduce(parts, {:lit, ""}, fn part, acc -> {:binop, "&", acc, part_expr(part)} end)
    end
  end

  @spec part_expr({:lit, String.t()} | {:expr, tuple()}) :: tuple()
  defp part_expr({:lit, s}), do: {:lit, s}
  defp part_expr({:expr, ast}), do: ast

  @spec split_interp(binary(), binary(), [tuple()]) :: [tuple()]
  defp split_interp(<<"##", rest::binary>>, buf, acc), do: split_interp(rest, buf <> "#", acc)

  defp split_interp(<<"#", rest::binary>>, buf, acc) do
    {inner, rest} = read_until_hash(rest, "")
    {expr, _} = inner |> Lexer.tokenize() |> parse_expr()
    split_interp(rest, "", [{:expr, expr} | flush_literal(buf, acc)])
  end

  defp split_interp(<<c::utf8, rest::binary>>, buf, acc),
    do: split_interp(rest, buf <> <<c::utf8>>, acc)

  defp split_interp("", buf, acc), do: Enum.reverse(flush_literal(buf, acc))

  @spec flush_literal(binary(), [tuple()]) :: [tuple()]
  defp flush_literal("", acc), do: acc
  defp flush_literal(buf, acc), do: [{:lit, buf} | acc]

  @spec read_until_hash(binary(), binary()) :: {binary(), binary()}
  defp read_until_hash(<<"#", rest::binary>>, acc), do: {acc, rest}

  defp read_until_hash(<<c::utf8, rest::binary>>, acc),
    do: read_until_hash(rest, acc <> <<c::utf8>>)

  defp read_until_hash("", acc), do: {acc, ""}

  ## Primary expressions

  @spec parse_primary([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_primary([{:int, n} | rest]), do: {{:lit, n}, rest}
  defp parse_primary([{:float, f} | rest]), do: {{:lit, f}, rest}
  defp parse_primary([{:string, s} | rest]), do: {interpolate(s), rest}

  # `(params) => ...` arrow function, or a parenthesized expression.
  defp parse_primary([{:op, "("} | _] = tokens) do
    if arrow_ahead?(tokens) do
      parse_arrow_with_params(tokens)
    else
      [_open | rest] = tokens
      {expr, rest} = parse_expr(rest)
      {expr, expect_op(rest, ")")}
    end
  end

  # Array literal: [a, b, c]
  defp parse_primary([{:op, "["} | rest]) do
    {elements, rest} = parse_list_until(rest, "]", [])
    {{:array, elements}, rest}
  end

  # Struct literal: {key: val, "k2" = v2}
  defp parse_primary([{:op, "{"} | rest]) do
    {pairs, rest} = parse_struct_pairs(rest, [])
    {{:struct, pairs}, rest}
  end

  defp parse_primary([{:ident, w} | rest] = tokens) do
    cond do
      kw?(w, "true") -> {{:lit, true}, rest}
      kw?(w, "false") -> {{:lit, false}, rest}
      kw?(w, "null") -> {{:lit, nil}, rest}
      kw?(w, "new") -> parse_new(rest)
      kw?(w, "function") and match?([{:op, "("} | _], rest) -> parse_anon_function(rest)
      match?([{:op, "=>"} | _], rest) -> parse_arrow_body([%AST.Param{name: w}], tl(rest))
      true -> {{:var, w}, tokens |> tl()}
    end
  end

  defp parse_primary(tokens) do
    raise "ExML.CFScript.Parser: unexpected token in expression: #{inspect(Enum.take(tokens, 3))}"
  end

  # `new cfc.foo.bar(args)` → {:new, "cfc.foo.bar", args}
  @spec parse_new([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_new(tokens) do
    {path, tokens} = parse_dotted_path(tokens, [])
    tokens = expect_op(tokens, "(")
    {args, tokens} = parse_args(tokens, [])
    {{:new, path, args}, tokens}
  end

  @spec parse_dotted_path([Lexer.token()], [String.t()]) :: {String.t(), [Lexer.token()]}
  defp parse_dotted_path([{:ident, seg}, {:op, "."} | rest], acc),
    do: parse_dotted_path(rest, [seg | acc])

  defp parse_dotted_path([{:ident, seg} | rest], acc),
    do: {Enum.reverse([seg | acc]) |> Enum.join("."), rest}

  defp parse_dotted_path([{:string, path} | rest], []), do: {path, rest}

  # Anonymous `function(params) { body }`
  @spec parse_anon_function([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_anon_function(tokens) do
    tokens = expect_op(tokens, "(")
    {params, tokens} = parse_params(tokens, [])
    tokens = expect_op(tokens, ")")
    tokens = skip_function_attrs(tokens)
    tokens = expect_op(tokens, "{")
    {body, tokens} = parse_statements(tokens, [])
    tokens = expect_op(tokens, "}")
    {{:fun, params, body}, tokens}
  end

  # Whether `( ... )` is immediately followed by `=>` (an arrow's param list)
  # rather than being a parenthesized expression.
  @spec arrow_ahead?([Lexer.token()]) :: boolean()
  defp arrow_ahead?([{:op, "("} | rest]),
    do: match?([{:op, "=>"} | _], skip_balanced_parens(rest, 1))

  @spec skip_balanced_parens([Lexer.token()], non_neg_integer()) :: [Lexer.token()]
  defp skip_balanced_parens(tokens, 0), do: tokens
  defp skip_balanced_parens([], _depth), do: []
  defp skip_balanced_parens([{:op, "("} | rest], depth), do: skip_balanced_parens(rest, depth + 1)
  defp skip_balanced_parens([{:op, ")"} | rest], depth), do: skip_balanced_parens(rest, depth - 1)
  defp skip_balanced_parens([_token | rest], depth), do: skip_balanced_parens(rest, depth)

  # `(params) => expr_or_block`
  @spec parse_arrow_with_params([Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_arrow_with_params(tokens) do
    tokens = expect_op(tokens, "(")
    {params, tokens} = parse_params(tokens, [])
    tokens = expect_op(tokens, ")")
    tokens = expect_op(tokens, "=>")
    parse_arrow_body(params, tokens)
  end

  # Arrow body: a `{ ... }` block, or a single expression (implicit return).
  @spec parse_arrow_body([AST.Param.t()], [Lexer.token()]) :: {tuple(), [Lexer.token()]}
  defp parse_arrow_body(params, [{:op, "{"} | rest]) do
    {body, rest} = parse_statements(rest, [])
    {{:fun, params, body}, expect_op(rest, "}")}
  end

  defp parse_arrow_body(params, tokens) do
    {expr, rest} = parse_expr(tokens)
    {{:fun, params, [{:return, expr}]}, rest}
  end

  ## Token utilities

  @spec kw?(String.t(), String.t()) :: boolean()
  defp kw?(word, keyword), do: String.downcase(word) == keyword

  @spec take_ident([Lexer.token()]) :: {String.t(), [Lexer.token()]}
  defp take_ident([{:ident, name} | rest]), do: {name, rest}

  defp take_ident(tokens),
    do: raise("ExML.CFScript.Parser: expected identifier near #{inspect(Enum.take(tokens, 3))}")

  @spec expect_ident([Lexer.token()], String.t()) :: [Lexer.token()]
  defp expect_ident([{:ident, w} | rest], expected) do
    if kw?(w, expected),
      do: rest,
      else: raise("ExML.CFScript.Parser: expected '#{expected}', got #{inspect(w)}")
  end

  defp expect_ident(tokens, expected),
    do:
      raise("ExML.CFScript.Parser: expected '#{expected}' near #{inspect(Enum.take(tokens, 3))}")

  @spec expect_op([Lexer.token()], String.t()) :: [Lexer.token()]
  defp expect_op([{:op, op} | rest], op), do: rest

  defp expect_op(tokens, op),
    do: raise("ExML.CFScript.Parser: expected '#{op}' near #{inspect(Enum.take(tokens, 3))}")

  @spec drop_semicolon([Lexer.token()]) :: [Lexer.token()]
  defp drop_semicolon([{:op, ";"} | rest]), do: rest
  defp drop_semicolon(tokens), do: tokens
end
