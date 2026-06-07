defmodule ExML.CFScript.Interpreter do
  @moduledoc """
  Tree-walking evaluator for the cfscript AST.

  Evaluates statements and expressions against an `ExML.CFScript.Env`. Handles
  component instantiation (`new cfc.foo()`), instance and static method dispatch
  (`obj.m()`, `cfc.foo::m()`), string member functions (`s.trim()`), closures,
  injected native functions (`describe`/`it`/`assert_*`), and built-in
  functions (`len`, `ucase`, ...).

  `return` unwinds via a `throw({:return, value})` caught at the call boundary.
  """

  alias ExML.CFScript.{
    AST,
    CFException,
    Collections,
    Context,
    Env,
    Heap,
    Loader,
    NativeObject,
    Query,
    Scope,
    Struct,
    Value
  }

  alias ExML.CFScript.Value.{
    ArrayRef,
    Closure,
    ComponentType,
    Instance,
    Namespace,
    Native,
    QueryRef,
    StructRef
  }

  # Call-frame scopes (held on the Env).
  @scopes ~w(arguments local variables this static)

  # Run-wide predefined CFML scopes (held on Context.scopes), normally populated
  # by the Application.cfc request lifecycle, which we don't run — the host seeds
  # them instead. `client`/`session` are intentionally not modelled.
  @predefined_scopes ~w(request application cgi server url form)
  @all_scopes @scopes ++ @predefined_scopes

  @doc "The run-wide predefined CFML scope names (for the host to seed)."
  @spec predefined_scopes() :: [String.t()]
  def predefined_scopes, do: @predefined_scopes

  ## Public entry points

  @doc "Instantiate a parsed component, returning an `Instance` with a fresh variables scope."
  @spec instantiate(AST.Component.t(), String.t(), Context.t()) :: Instance.t()
  def instantiate(%AST.Component{} = component, type_path, %Context{} = ctx) do
    instance = new_instance(component, type_path)

    # Run a zero-arg `init` constructor if the component defines one.
    if function_named(component, "init") do
      _ = invoke_method(instance, "init", [], %{}, ctx)
    end

    instance
  end

  @spec new_instance(AST.Component.t(), String.t()) :: Instance.t()
  defp new_instance(component, type_path) do
    %Instance{type_path: type_path, component: component, variables: Scope.new()}
  end

  @doc "Invoke a method on an instance by name, returning its result."
  @spec call_instance_method(Instance.t(), String.t(), [any()], Context.t()) :: any()
  def call_instance_method(%Instance{} = instance, name, args, ctx) do
    invoke_method(instance, name, args, %{}, ctx)
  end

  # Instance method call with positional + named arguments.
  @spec invoke_method(Instance.t(), String.t(), [any()], map(), Context.t()) :: any()
  defp invoke_method(%Instance{component: component} = instance, name, pos, named, ctx) do
    func = function_named!(component, name, instance.type_path)
    call_function(func, pos, named, instance, instance.type_path, component, ctx)
  end

  @doc "Invoke a closure or native function value with already-evaluated arguments."
  @spec invoke(any(), [any()], Env.t()) :: any()
  def invoke(%Closure{params: params, body: body, env: cenv}, args, _env) do
    arguments = bind_arguments(params, args, cenv)

    inner = %Env{
      arguments: arguments,
      local: Scope.new(),
      variables: cenv.variables,
      this: cenv.this,
      default_scope: :local,
      static_scope: cenv.static_scope,
      component: cenv.component,
      type_path: cenv.type_path,
      ctx: cenv.ctx
    }

    run_body(body, inner)
  end

  def invoke(%Native{fun: fun}, args, env), do: fun.(args, env)

  def invoke(other, _args, _env) do
    raise CFException, message: "Value is not callable: #{Value.to_str(other)}"
  end

  ## Statement execution

  @spec run_body([tuple()], Env.t()) :: any()
  defp run_body(stmts, env) do
    Enum.each(stmts, &eval_stmt(&1, env))
    nil
  catch
    {:return, value} -> value
  end

  @spec eval_stmt(tuple(), Env.t()) :: any()
  defp eval_stmt({:return, nil}, _env), do: throw({:return, nil})
  defp eval_stmt({:return, expr}, env), do: throw({:return, eval(expr, env)})

  defp eval_stmt({:var, name, expr}, env) do
    Scope.put(env.local, name, eval(expr, env))
  end

  defp eval_stmt({:assign, target, expr}, env) do
    assign(target, eval(expr, env), env)
  end

  defp eval_stmt({:expr, expr}, env), do: eval(expr, env)

  defp eval_stmt({:if, cond_expr, then_stmts, else_stmts}, env) do
    if Value.truthy?(eval(cond_expr, env)) do
      Enum.each(then_stmts, &eval_stmt(&1, env))
    else
      Enum.each(else_stmts, &eval_stmt(&1, env))
    end
  end

  # `x++` / `x--` — increment/decrement an lvalue by 1.
  defp eval_stmt({:incr, target, op}, env) do
    current = Value.to_number(eval(target, env))
    delta = if op == "+", do: 1, else: -1
    assign(target, current + delta, env)
  end

  # C-style for: run init, then loop while cond is truthy, running body then incr.
  defp eval_stmt({:for, init, cond_expr, incr, body}, env) do
    eval_stmt(init, env)

    loop_while(fn -> Value.truthy?(eval(cond_expr, env)) end, fn ->
      Enum.each(body, &eval_stmt(&1, env))
      eval_stmt(incr, env)
    end)
  end

  # for-in: iterate the collection's elements (array values / struct keys /
  # query row indices), binding `name` each iteration.
  defp eval_stmt({:for_in, name, coll_expr, body}, env) do
    coll_expr
    |> eval(env)
    |> iterable_items()
    |> Enum.each(fn item ->
      assign({:var, name}, item, env)
      Enum.each(body, &eval_stmt(&1, env))
    end)
  end

  defp eval_stmt({:while, cond_expr, body}, env) do
    loop_while(fn -> Value.truthy?(eval(cond_expr, env)) end, fn ->
      Enum.each(body, &eval_stmt(&1, env))
    end)
  end

  # break/continue unwind via throw, caught by the enclosing switch (break only).
  defp eval_stmt({:break}, _env), do: throw(:break)
  defp eval_stmt({:continue}, _env), do: throw(:continue)

  # switch: evaluate the subject, then run from the first matching `case` (or
  # `default` if none match), falling through subsequent clauses until a `break`.
  defp eval_stmt({:switch, subject_expr, clauses}, env) do
    value = eval(subject_expr, env)

    case switch_start_index(clauses, value, env) do
      nil ->
        nil

      index ->
        try do
          clauses |> Enum.drop(index) |> Enum.each(&run_switch_clause(&1, env))
        catch
          :break -> nil
        end
    end
  end

  # try { } catch (Type e) { } ... [finally { }]. `return`/loop control unwind
  # via throw, which `rescue` ignores (so they propagate) while `after` still
  # runs the finally block.
  defp eval_stmt({:try, body, catches, finally}, env) do
    try do
      Enum.each(body, &eval_stmt(&1, env))
    rescue
      error -> handle_catch(error, catches, env, __STACKTRACE__)
    after
      Enum.each(finally, &eval_stmt(&1, env))
    end
  end

  # The clause to start at: the first matching `case`, else the `default`, else
  # nil (no clause runs).
  @spec switch_start_index([tuple()], any(), Env.t()) :: non_neg_integer() | nil
  defp switch_start_index(clauses, value, env) do
    matched =
      Enum.find_index(clauses, fn
        {:case, value_expr, _stmts} -> Value.equals?(value, eval(value_expr, env))
        {:default, _stmts} -> false
      end)

    matched || Enum.find_index(clauses, &match?({:default, _}, &1))
  end

  @spec run_switch_clause(tuple(), Env.t()) :: any()
  defp run_switch_clause({:case, _value, stmts}, env), do: Enum.each(stmts, &eval_stmt(&1, env))
  defp run_switch_clause({:default, stmts}, env), do: Enum.each(stmts, &eval_stmt(&1, env))

  # Loop guard: a generous cap so a buggy condition can't hang the interpreter.
  @max_iterations 5_000_000
  @spec loop_while((-> boolean()), (-> any())) :: :ok
  defp loop_while(condition, body), do: loop_while(condition, body, 0)

  defp loop_while(_condition, _body, n) when n >= @max_iterations do
    raise CFException,
      message: "loop exceeded #{@max_iterations} iterations (possible infinite loop)"
  end

  defp loop_while(condition, body, n) do
    if condition.() do
      body.()
      loop_while(condition, body, n + 1)
    else
      :ok
    end
  end

  # Match a raised exception against the catch clauses; run the first whose type
  # matches (binding the exception struct to its variable), else re-raise.
  @spec handle_catch(Exception.t(), [tuple()], Env.t(), Exception.stacktrace()) :: any()
  defp handle_catch(error, catches, env, stacktrace) do
    ex = exception_struct(error)

    case Enum.find(catches, fn {type, _var, _body} -> catch_matches?(type, ex["type"]) end) do
      {_type, var, body} ->
        Scope.put(env.local, var, Heap.new_struct(ex))
        Enum.each(body, &eval_stmt(&1, env))

      nil ->
        reraise(error, stacktrace)
    end
  end

  @spec catch_matches?(String.t(), String.t()) :: boolean()
  defp catch_matches?(catch_type, ex_type) do
    down = String.downcase(catch_type)
    down in ["any", ""] or down == String.downcase(ex_type)
  end

  # Build the CFML cfcatch struct from a raised exception.
  @spec exception_struct(Exception.t()) :: map()
  defp exception_struct(%CFException{message: msg, cf_type: type, detail: detail}) do
    base_exception(type, msg, detail)
  end

  defp exception_struct(error) do
    base_exception("Application", Exception.message(error), "")
  end

  defp base_exception(type, message, detail) do
    %{
      "type" => to_string(type),
      "message" => to_string(message),
      "detail" => to_string(detail),
      "errorcode" => "",
      "extendedinfo" => "",
      "stacktrace" => ""
    }
  end

  # What `for (x in coll)` iterates: array values, struct keys, or list elements.
  @spec iterable_items(any()) :: [any()]
  defp iterable_items(value) do
    case Heap.deref(value) do
      list when is_list(list) -> list
      map when is_map(map) and not is_struct(map) -> Map.keys(map)
      other -> raise CFException, message: "Cannot iterate over #{Value.display(other)}"
    end
  end

  ## Assignment

  @spec assign(tuple(), any(), Env.t()) :: any()
  defp assign({:var, name}, value, env) do
    scope = target_scope(name, env)
    Scope.put(scope, name, value)
    value
  end

  defp assign({:member, {:var, scope_kw}, name}, value, env) when scope_kw in @all_scopes do
    Scope.put(scope_ref(scope_kw, env), name, value)
    value
  end

  defp assign({:member, obj_ast, name}, value, env) do
    case eval(obj_ast, env) do
      %StructRef{} = ref ->
        Heap.write(ref, Struct.put(Heap.deref(ref), name, value))
        value

      %Instance{variables: variables} ->
        Scope.put(variables, name, value)
        value

      other ->
        raise CFException, message: "Cannot assign member '#{name}' on #{Value.display(other)}"
    end
  end

  # Indexed assignment: arr[i] = v / struct[key] = v (mutates in place).
  defp assign({:index, obj_ast, key_ast}, value, env) do
    key = eval(key_ast, env)

    case eval(obj_ast, env) do
      %ArrayRef{} = ref ->
        Heap.write(ref, array_set(Heap.deref(ref), Value.to_number(key), value))
        value

      %StructRef{} = ref ->
        Heap.write(ref, Struct.put(Heap.deref(ref), Value.to_str(key), value))
        value

      other ->
        raise CFException, message: "Cannot assign by index on #{Value.display(other)}"
    end
  end

  # Pick the scope an unscoped assignment writes to: an already-bound name keeps
  # its scope, otherwise the function's default (local for localmode functions,
  # variables otherwise).
  @spec target_scope(String.t(), Env.t()) :: Scope.t()
  defp target_scope(name, env) do
    cond do
      Scope.has?(env.local, name) -> env.local
      Scope.has?(env.arguments, name) -> env.arguments
      Scope.has?(env.variables, name) -> env.variables
      env.default_scope == :variables -> env.variables
      true -> env.local
    end
  end

  ## Expression evaluation

  @spec eval(tuple(), Env.t()) :: any()
  defp eval({:lit, value}, _env), do: value

  # Scope-qualified read: arguments.x / local.x / variables.x / this.x
  defp eval({:member, {:var, scope_kw}, name}, env) when scope_kw in @all_scopes do
    read_scope_member(scope_kw, name, env)
  end

  defp eval({:member, obj_ast, name}, env), do: eval_member(eval(obj_ast, env), name, env)

  defp eval({:var, name}, env), do: resolve_var(name, env)

  defp eval({:index, obj_ast, key_ast}, env) do
    obj = eval(obj_ast, env)
    key = eval(key_ast, env)

    case Heap.deref(obj) do
      list when is_list(list) -> array_index(list, Value.to_number(key))
      m when is_map(m) -> struct_index(m, String.downcase(Value.to_str(key)), env)
      other -> raise CFException, message: "Cannot index #{Value.display(other)}"
    end
  end

  defp eval({:new, path, args}, env) do
    {pos, named} = eval_args(args, env)
    instantiate_path(path, pos, named, env)
  end

  # Array/struct literals create fresh mutable references (reference types).
  defp eval({:array, elements}, env) do
    Heap.new_array(Enum.map(elements, &eval(&1, env)))
  end

  # Struct literal: keys keep their original case (CFML structs are
  # case-preserving). With full-null-support off, a null value means the key is
  # absent, so such pairs are dropped.
  defp eval({:struct, pairs}, env) do
    keep_nulls = env.ctx.null_support

    map =
      for {key, value_ast} <- pairs,
          value = eval(value_ast, env),
          keep_nulls or not is_nil(value),
          into: %{},
          do: {key, value}

    Heap.new_struct(map)
  end

  defp eval({:fun, params, body}, env) do
    %Closure{params: params, body: body, env: env}
  end

  defp eval({:unop, "not", expr}, env), do: not Value.truthy?(eval(expr, env))
  defp eval({:unop, "-", expr}, env), do: -Value.to_number(eval(expr, env))

  defp eval({:binop, "and", l, r}, env),
    do: Value.truthy?(eval(l, env)) and Value.truthy?(eval(r, env))

  defp eval({:binop, "or", l, r}, env),
    do: Value.truthy?(eval(l, env)) or Value.truthy?(eval(r, env))

  defp eval({:binop, op, l, r}, env), do: eval_binop(op, eval(l, env), eval(r, env))

  defp eval({:call, callee, args}, env), do: eval_call(callee, args, env)

  defp eval(other, _env), do: raise(CFException, message: "Cannot evaluate: #{inspect(other)}")

  @spec eval_binop(String.t(), any(), any()) :: any()
  defp eval_binop("&", l, r), do: Value.to_str(l) <> Value.to_str(r)
  defp eval_binop("==", l, r), do: Value.equals?(l, r)
  defp eval_binop("!=", l, r), do: not Value.equals?(l, r)
  defp eval_binop("<", l, r), do: Value.compare(l, r) == :lt
  defp eval_binop(">", l, r), do: Value.compare(l, r) == :gt
  defp eval_binop("<=", l, r), do: Value.compare(l, r) in [:lt, :eq]
  defp eval_binop(">=", l, r), do: Value.compare(l, r) in [:gt, :eq]
  defp eval_binop("+", l, r), do: Value.to_number(l) + Value.to_number(r)
  defp eval_binop("-", l, r), do: Value.to_number(l) - Value.to_number(r)
  defp eval_binop("*", l, r), do: Value.to_number(l) * Value.to_number(r)
  defp eval_binop("/", l, r), do: Value.to_number(l) / Value.to_number(r)

  defp eval_binop("%", l, r),
    do: rem(trunc(Value.to_number(l)), trunc(Value.to_number(r)))

  ## Calls

  @spec eval_call(tuple(), [tuple()], Env.t()) :: any()
  # Static method: cfc.foo::method(args)
  defp eval_call({:static_member, obj_ast, name}, args, env) do
    {pos, named} = eval_args(args, env)
    %ComponentType{component: component, path: path} = resolve_component_type(obj_ast, env)
    func = function_named!(component, name, path)
    call_function(func, pos, named, nil, path, component, env.ctx)
  end

  # Member call: obj.method(args) — instance method or string member function.
  defp eval_call({:member, {:var, scope_kw}, name}, args, env) when scope_kw in @all_scopes do
    {pos, named} = eval_args(args, env)
    dispatch_member_call(read_scope_value(scope_kw, env), name, pos, named, env)
  end

  defp eval_call({:member, obj_ast, name}, args, env) do
    {pos, named} = eval_args(args, env)
    dispatch_member_call(eval(obj_ast, env), name, pos, named, env)
  end

  # Bare call: name(args)
  defp eval_call({:var, name}, args, env) do
    {pos, named} = eval_args(args, env)
    call_named(name, pos, named, env)
  end

  # Any other callee expression must evaluate to a callable (positional only).
  defp eval_call(callee_ast, args, env) do
    {pos, _named} = eval_args(args, env)
    invoke(eval(callee_ast, env), pos, env)
  end

  @spec dispatch_member_call(any(), String.t(), [any()], map(), Env.t()) :: any()
  defp dispatch_member_call(%Instance{} = inst, name, pos, named, env) do
    invoke_method(inst, name, pos, named, env.ctx)
  end

  # Host object (e.g. a Logger-backed `request.logger`): dispatch to its native
  # method. `:__self__` returns the object itself (builder-style chaining).
  defp dispatch_member_call(%NativeObject{} = obj, name, pos, _named, _env) do
    case NativeObject.invoke(obj, name, pos) do
      :__self__ -> obj
      result -> result
    end
  end

  # Strings, arrays, and structs delegate to the member->BIF/HigherOrder glue,
  # supplying an invoker so callback members can run UDFs (positional only).
  defp dispatch_member_call(value, name, pos, _named, env) do
    Collections.member_call(value, name, pos, invoker(env))
  end

  # Resolve a bare call name: a callable variable, then a sibling method, then an
  # injected native, then `throw`/`queryExecute`, then a built-in function.
  @spec call_named(String.t(), [any()], map(), Env.t()) :: any()
  defp call_named(name, pos, named, env) do
    down = String.downcase(name)

    cond do
      (callable = callable_var(name, env)) != :none ->
        invoke(callable, pos, env)

      sibling_function(env, name) != nil ->
        call_sibling(sibling_function(env, name), name, pos, named, env)

      Map.has_key?(env.ctx.natives, down) ->
        invoke(Map.fetch!(env.ctx.natives, down), pos, env)

      down == "throw" ->
        do_throw(pos, named)

      down == "queryexecute" ->
        exec_query(pos, env)

      Collections.handles?(name) ->
        Collections.call(name, pos, invoker(env))

      true ->
        raise CFException, message: "Undefined function: #{name}"
    end
  end

  # throw(message=, type=, detail=) or throw("message"); raises a CFException.
  @spec do_throw([any()], map()) :: no_return()
  defp do_throw(pos, named) do
    message = Map.get(named, "message") || List.first(pos) || ""
    type = Map.get(named, "type", "Application")
    detail = Map.get(named, "detail", "")

    raise CFException,
      cf_type: Value.to_str(type),
      message: Value.to_str(message),
      detail: Value.to_str(detail)
  end

  # A function defined on the currently-executing component (sibling method).
  @spec sibling_function(Env.t(), String.t()) :: AST.Function.t() | nil
  defp sibling_function(%Env{component: %AST.Component{} = component}, name),
    do: function_named(component, name)

  defp sibling_function(_env, _name), do: nil

  # Call a sibling method: as an instance method when in instance context,
  # otherwise as a static call (preserving the component's static scope).
  @spec call_sibling(AST.Function.t(), String.t(), [any()], map(), Env.t()) :: any()
  defp call_sibling(_func, name, pos, named, %Env{this: %Instance{} = instance} = env),
    do: invoke_method(instance, name, pos, named, env.ctx)

  defp call_sibling(func, _name, pos, named, env),
    do: call_function(func, pos, named, nil, env.type_path, env.component, env.ctx)

  # queryExecute(sql [, params [, options]]). The actual SQL runs through the
  # pluggable Context.query_executor (e.g. an Ecto repo, when wired into a host
  # Phoenix app); without one configured it raises. options.returnType selects
  # "query" (default, a QueryRef) or "array" (an array of row structs).
  @spec exec_query([any()], Env.t()) :: any()
  defp exec_query(args, %Env{ctx: ctx}) do
    executor = ctx.query_executor || no_executor()
    sql = Value.to_str(Enum.at(args, 0))
    params = Collections.deep_deref(Enum.at(args, 1, %{}))
    options = Collections.deep_deref(Enum.at(args, 2, %{}))

    query = Query.from_result(executor.(sql, params))

    case options |> Struct.get("returntype") |> normalize_return_type() do
      "array" ->
        query |> Query.to_array() |> Enum.map(&Heap.new_struct/1) |> Heap.new_array()

      _ ->
        Heap.new_query(query)
    end
  end

  @spec no_executor() :: no_return()
  defp no_executor do
    raise CFException,
      message:
        "queryExecute requires a configured query executor; run from a host app with a repo or pass :query_executor"
  end

  @spec normalize_return_type(any()) :: String.t()
  defp normalize_return_type(nil), do: "query"
  defp normalize_return_type(value), do: value |> Value.to_str() |> String.downcase()

  # An invoker closure for higher-order functions: runs a UDF (closure/native)
  # with evaluated args in the current environment.
  @spec invoker(Env.t()) :: (any(), [any()] -> any())
  defp invoker(env), do: fn callable, call_args -> invoke(callable, call_args, env) end

  @spec callable_var(String.t(), Env.t()) :: any() | :none
  defp callable_var(name, env) do
    with :error <- Scope.fetch(env.local, name),
         :error <- Scope.fetch(env.arguments, name),
         :error <- Scope.fetch(env.variables, name) do
      :none
    else
      {:ok, %Closure{} = c} -> c
      {:ok, %Native{} = n} -> n
      _ -> :none
    end
  end

  ## Function invocation (instance + static, AST-defined)

  @spec call_function(
          AST.Function.t(),
          [any()],
          map(),
          Instance.t() | nil,
          String.t(),
          AST.Component.t(),
          Context.t()
        ) :: any()
  defp call_function(%AST.Function{} = func, pos, named, instance, type_path, component, ctx) do
    variables = if instance, do: instance.variables, else: Scope.new()
    arguments = Scope.new()

    base_env = %Env{
      arguments: arguments,
      local: Scope.new(),
      variables: variables,
      this: instance,
      default_scope: if(func.localmode, do: :local, else: :variables),
      static_scope: ensure_static_scope(type_path, component, ctx),
      component: component,
      type_path: type_path,
      ctx: ctx
    }

    bind_params(func.params, pos, named, arguments, base_env)
    run_body(func.body, base_env)
  end

  # The component's shared `static` scope, created and populated (by running the
  # `static { ... }` initializer once) on first use. Keyed by type_path so all
  # instances/static calls of a component share one static scope per run.
  @spec ensure_static_scope(String.t(), AST.Component.t(), Context.t()) :: Scope.t()
  defp ensure_static_scope(type_path, component, ctx) do
    key = {__MODULE__, :static, type_path}

    case Process.get(key) do
      nil ->
        scope = Scope.new()
        Process.put(key, scope)
        run_static_init(component, scope, type_path, ctx)
        scope

      scope ->
        scope
    end
  end

  @spec run_static_init(AST.Component.t(), Scope.t(), String.t(), Context.t()) :: :ok
  defp run_static_init(%AST.Component{static_init: []}, _scope, _type_path, _ctx), do: :ok

  defp run_static_init(%AST.Component{static_init: stmts} = component, scope, type_path, ctx) do
    # During init, unscoped assignments and `static.x` both target the static
    # scope (variables is aliased to it).
    env = %Env{
      arguments: Scope.new(),
      local: Scope.new(),
      variables: scope,
      this: nil,
      default_scope: :variables,
      static_scope: scope,
      component: component,
      type_path: type_path,
      ctx: ctx
    }

    Enum.each(stmts, &eval_stmt(&1, env))
  end

  # Bind positional, then named, then default args into the arguments `scope`
  # (positional by index; named by param name, case-insensitively).
  @spec bind_params([AST.Param.t()], [any()], map(), Scope.t(), Env.t()) :: :ok
  defp bind_params(params, pos, named, scope, env) do
    params
    |> Enum.with_index()
    |> Enum.each(fn {%AST.Param{} = param, idx} ->
      key = String.downcase(param.name)

      cond do
        idx < length(pos) ->
          Scope.put(scope, param.name, Enum.at(pos, idx))

        Map.has_key?(named, key) ->
          Scope.put(scope, param.name, Map.fetch!(named, key))

        param.default != nil ->
          Scope.put(scope, param.name, eval(param.default, env))

        param.required ->
          raise CFException, message: "Missing required argument: #{param.name}"

        true ->
          :noop
      end
    end)

    :ok
  end

  # Closures bind args without required/default enforcement (slice scope).
  @spec bind_arguments([AST.Param.t()], [any()], Env.t()) :: Scope.t()
  defp bind_arguments(params, args, cenv) do
    scope = Scope.new()

    params
    |> Enum.with_index()
    |> Enum.each(fn {%AST.Param{name: name, default: default}, idx} ->
      value = if idx < length(args), do: Enum.at(args, idx), else: default && eval(default, cenv)
      Scope.put(scope, name, value)
    end)

    scope
  end

  ## Member / scope reads

  @spec eval_member(any(), String.t(), Env.t()) :: any()
  defp eval_member(%Namespace{base: base}, name, env) do
    resolve_component_type_by_path("#{base}.#{name}", env.ctx)
  end

  defp eval_member(%Instance{variables: variables}, name, env) do
    case Scope.fetch(variables, name) do
      {:ok, value} -> value
      :error -> missing_key(name, env)
    end
  end

  defp eval_member(%StructRef{} = ref, name, env) do
    case Struct.fetch(Heap.deref(ref), name) do
      {:ok, value} -> value
      :error -> missing_key(name, env)
    end
  end

  defp eval_member(%ArrayRef{}, name, _env) do
    raise CFException, message: "Arrays have no member '#{name}' (use index access)"
  end

  # Query member access: pseudo-columns (recordCount/columnList/...) yield
  # scalars; a real column name yields that column's values (1-based indexable).
  defp eval_member(%QueryRef{} = ref, name, env) do
    q = Heap.deref(ref)

    case String.downcase(name) do
      "recordcount" -> Query.record_count(q)
      "columnlist" -> Query.column_list(q)
      "columncount" -> Query.column_count(q)
      "currentrow" -> 1
      _ -> if Query.column?(q, name), do: Query.column_data(q, name), else: missing_key(name, env)
    end
  end

  defp eval_member(map, name, env) when is_map(map) do
    case Struct.fetch(map, name) do
      {:ok, value} -> value
      :error -> missing_key(name, env)
    end
  end

  defp eval_member(other, name, _env) do
    raise CFException, message: "Cannot read member '#{name}' on #{Value.display(other)}"
  end

  @spec read_scope_member(String.t(), String.t(), Env.t()) :: any()
  defp read_scope_member("this", name, env), do: eval_member(env.this, name, env)

  defp read_scope_member(scope_kw, name, env) do
    case Scope.fetch(scope_ref(scope_kw, env), name) do
      {:ok, value} -> value
      :error -> missing_key(name, env)
    end
  end

  # Honor Lucee's full-null-support setting: with it off (the common default),
  # reading a missing key raises; with it on, it yields null.
  @spec missing_key(String.t(), Env.t()) :: nil
  defp missing_key(_name, %Env{ctx: %{null_support: true}}), do: nil

  defp missing_key(name, _env) do
    raise CFException, message: "key [#{name}] doesn't exist"
  end

  # Array element read (1-based). Out-of-range always raises in CFML.
  @spec array_index([any()], number()) :: any()
  defp array_index(list, index) do
    i = trunc(index)

    if i < 1 or i > length(list) do
      raise CFException, message: "Array index [#{i}] out of range, array size is #{length(list)}"
    end

    Enum.at(list, i - 1)
  end

  @spec struct_index(map(), String.t(), Env.t()) :: any()
  defp struct_index(map, key, env) do
    case Struct.fetch(map, key) do
      {:ok, value} -> value
      :error -> missing_key(key, env)
    end
  end

  # Array element write (1-based); extends the array (padding with "") when the
  # index is beyond the current size, matching Lucee's null-less behavior.
  @spec array_set([any()], number(), any()) :: [any()]
  defp array_set(list, index, value) do
    i = trunc(index)

    if i < 1 do
      raise CFException, message: "Array index [#{i}] must be a positive integer"
    end

    list
    |> pad_to(i)
    |> List.replace_at(i - 1, value)
  end

  @spec pad_to([any()], pos_integer()) :: [any()]
  defp pad_to(list, size) when length(list) >= size, do: list
  defp pad_to(list, size), do: list ++ List.duplicate("", size - length(list))

  # The value of a bare scope keyword (e.g. passing `arguments` to a BIF).
  @spec read_scope_value(String.t(), Env.t()) :: any()
  defp read_scope_value("this", env), do: env.this
  defp read_scope_value(scope_kw, env), do: Scope.to_map(scope_ref(scope_kw, env))

  @spec scope_ref(String.t(), Env.t()) :: Scope.t()
  defp scope_ref("arguments", env), do: env.arguments
  defp scope_ref("local", env), do: env.local
  defp scope_ref("variables", env), do: env.variables
  defp scope_ref("static", env), do: env.static_scope

  # Predefined run-wide scopes (request/application/cgi/...) live on the context.
  defp scope_ref(name, env) do
    case Map.fetch(env.ctx.scopes, name) do
      {:ok, scope} -> scope
      :error -> raise CFException, message: "Scope '#{name}' is not available"
    end
  end

  @spec resolve_var(String.t(), Env.t()) :: any()
  defp resolve_var(name, env) do
    down = String.downcase(name)

    cond do
      down == "cfc" ->
        %Namespace{base: "cfc"}

      down in ["arguments", "local", "variables"] or down in @predefined_scopes ->
        read_scope_value(down, env)

      down == "this" ->
        env.this

      (v = lookup_scopes(name, env)) != :none ->
        v

      Map.has_key?(env.ctx.natives, String.downcase(name)) ->
        Map.fetch!(env.ctx.natives, String.downcase(name))

      true ->
        raise CFException, message: "Variable '#{name}' is undefined"
    end
  end

  @spec lookup_scopes(String.t(), Env.t()) :: any() | :none
  defp lookup_scopes(name, env) do
    with :error <- Scope.fetch(env.local, name),
         :error <- Scope.fetch(env.arguments, name),
         :error <- Scope.fetch(env.variables, name) do
      :none
    else
      {:ok, value} -> value
    end
  end

  ## Component resolution / loading

  # Evaluate an argument list into {positional_values, named_value_map}. Named
  # args (`name = expr`) collect into the map (keyed by downcased name); the
  # rest are positional, in order.
  @spec eval_args([tuple()], Env.t()) :: {[any()], map()}
  defp eval_args(args, env) do
    Enum.reduce(args, {[], %{}}, fn
      {:named, name, expr}, {pos, named} ->
        {pos, Map.put(named, String.downcase(name), eval(expr, env))}

      expr, {pos, named} ->
        {pos ++ [eval(expr, env)], named}
    end)
  end

  @spec resolve_component_type(tuple(), Env.t()) :: ComponentType.t()
  defp resolve_component_type(obj_ast, env) do
    case eval(obj_ast, env) do
      %ComponentType{} = type -> type
      other -> raise CFException, message: "Not a component type: #{Value.to_str(other)}"
    end
  end

  @spec resolve_component_type_by_path(String.t(), Context.t()) :: ComponentType.t()
  defp resolve_component_type_by_path(path, ctx) do
    %ComponentType{path: path, component: Loader.load(path, ctx)}
  end

  @spec instantiate_path(String.t(), [any()], map(), Env.t()) :: Instance.t()
  defp instantiate_path(path, pos, named, env) do
    component = Loader.load(path, env.ctx)
    instance = new_instance(component, path)

    # Run the `init` constructor (with the new-expression's args) if present.
    if function_named(component, "init") do
      _ = invoke_method(instance, "init", pos, named, env.ctx)
    end

    instance
  end

  ## Helpers

  @spec function_named(AST.Component.t(), String.t()) :: AST.Function.t() | nil
  defp function_named(%AST.Component{functions: functions}, name) do
    down = String.downcase(name)
    Enum.find(functions, fn %AST.Function{name: n} -> String.downcase(n) == down end)
  end

  @spec function_named!(AST.Component.t(), String.t(), String.t()) :: AST.Function.t()
  defp function_named!(component, name, type_path) do
    function_named(component, name) ||
      raise(CFException, message: "Component '#{type_path}' has no function '#{name}'")
  end
end
