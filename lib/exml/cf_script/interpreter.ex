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
    Query,
    Scope,
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

  @scopes ~w(arguments local variables this)

  ## Public entry points

  @doc "Instantiate a parsed component, returning an `Instance` with a fresh variables scope."
  @spec instantiate(AST.Component.t(), String.t(), Context.t()) :: Instance.t()
  def instantiate(%AST.Component{} = component, type_path, %Context{} = ctx) do
    variables = Scope.new()
    instance = %Instance{type_path: type_path, component: component, variables: variables}

    # Run an `init` constructor if the component defines one (no args for the slice).
    if function_named(component, "init") do
      _ = call_instance_method(instance, "init", [], ctx)
    end

    instance
  end

  @doc "Invoke a method on an instance by name, returning its result."
  @spec call_instance_method(Instance.t(), String.t(), [any()], Context.t()) :: any()
  def call_instance_method(%Instance{component: component} = instance, name, args, ctx) do
    func = function_named!(component, name, instance.type_path)
    call_function(func, args, instance, instance.type_path, ctx)
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

  ## Assignment

  @spec assign(tuple(), any(), Env.t()) :: any()
  defp assign({:var, name}, value, env) do
    scope = target_scope(name, env)
    Scope.put(scope, name, value)
    value
  end

  defp assign({:member, {:var, scope_kw}, name}, value, env) when scope_kw in @scopes do
    Scope.put(scope_ref(scope_kw, env), name, value)
    value
  end

  defp assign({:member, obj_ast, name}, value, env) do
    case eval(obj_ast, env) do
      %StructRef{} = ref ->
        Heap.write(ref, Map.put(Heap.deref(ref), String.downcase(name), value))
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
        Heap.write(ref, Map.put(Heap.deref(ref), String.downcase(Value.to_str(key)), value))
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
  defp eval({:member, {:var, scope_kw}, name}, env) when scope_kw in @scopes do
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
    instantiate_path(path, eval_args(args, env), env)
  end

  # Array/struct literals create fresh mutable references (reference types).
  defp eval({:array, elements}, env) do
    Heap.new_array(Enum.map(elements, &eval(&1, env)))
  end

  defp eval({:struct, pairs}, env) do
    map =
      for {key, value_ast} <- pairs, into: %{}, do: {String.downcase(key), eval(value_ast, env)}

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
    %ComponentType{component: component, path: path} = resolve_component_type(obj_ast, env)
    func = function_named!(component, name, path)
    call_function(func, eval_args(args, env), nil, path, env.ctx)
  end

  # Member call: obj.method(args) — instance method or string member function.
  defp eval_call({:member, {:var, scope_kw}, name}, args, env) when scope_kw in @scopes do
    dispatch_member_call(read_scope_value(scope_kw, env), name, eval_args(args, env), env)
  end

  defp eval_call({:member, obj_ast, name}, args, env) do
    dispatch_member_call(eval(obj_ast, env), name, eval_args(args, env), env)
  end

  # Bare call: name(args)
  defp eval_call({:var, name}, args, env), do: call_named(name, eval_args(args, env), env)

  # Any other callee expression must evaluate to a callable.
  defp eval_call(callee_ast, args, env) do
    invoke(eval(callee_ast, env), eval_args(args, env), env)
  end

  @spec dispatch_member_call(any(), String.t(), [any()], Env.t()) :: any()
  defp dispatch_member_call(%Instance{} = inst, name, args, env) do
    call_instance_method(inst, name, args, env.ctx)
  end

  # Strings, arrays, and structs delegate to the member->BIF/HigherOrder glue,
  # supplying an invoker so callback members can run UDFs.
  defp dispatch_member_call(value, name, args, env) do
    Collections.member_call(value, name, args, invoker(env))
  end

  # Resolve a bare call name: a callable variable, then a `this` method, then an
  # injected native, then a built-in function.
  @spec call_named(String.t(), [any()], Env.t()) :: any()
  defp call_named(name, args, env) do
    cond do
      (callable = callable_var(name, env)) != :none ->
        invoke(callable, args, env)

      match?(%Instance{}, env.this) and function_named(env.this.component, name) ->
        call_instance_method(env.this, name, args, env.ctx)

      Map.has_key?(env.ctx.natives, String.downcase(name)) ->
        invoke(Map.fetch!(env.ctx.natives, String.downcase(name)), args, env)

      String.downcase(name) == "queryexecute" ->
        exec_query(args, env)

      Collections.handles?(name) ->
        Collections.call(name, args, invoker(env))

      true ->
        raise CFException, message: "Undefined function: #{name}"
    end
  end

  # queryExecute(sql [, params [, options]]). The actual SQL runs through the
  # pluggable Context.query_executor (e.g. Macola.Repo when wired into the
  # Phoenix app); without one configured it raises. options.returnType selects
  # "query" (default, a QueryRef) or "array" (an array of row structs).
  @spec exec_query([any()], Env.t()) :: any()
  defp exec_query(args, %Env{ctx: ctx}) do
    executor = ctx.query_executor || no_executor()
    sql = Value.to_str(Enum.at(args, 0))
    params = Heap.deref(Enum.at(args, 1, %{}))
    options = Heap.deref(Enum.at(args, 2, %{}))

    query = Query.from_result(executor.(sql, params))

    case options |> Map.get("returntype") |> normalize_return_type() do
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
        "queryExecute requires a configured query executor; run from the Phoenix app (Macola.Repo) or pass :query_executor"
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

  @spec call_function(AST.Function.t(), [any()], Instance.t() | nil, String.t(), Context.t()) ::
          any()
  defp call_function(%AST.Function{} = func, args, instance, _type_path, ctx) do
    variables = if instance, do: instance.variables, else: Scope.new()
    arguments = Scope.new()

    base_env = %Env{
      arguments: arguments,
      local: Scope.new(),
      variables: variables,
      this: instance,
      default_scope: if(func.localmode, do: :local, else: :variables),
      ctx: ctx
    }

    bind_params(func.params, args, arguments, base_env)
    run_body(func.body, base_env)
  end

  # Bind positional args to params (with defaults / required checks) into `scope`.
  @spec bind_params([AST.Param.t()], [any()], Scope.t(), Env.t()) :: :ok
  defp bind_params(params, args, scope, env) do
    params
    |> Enum.with_index()
    |> Enum.each(fn {%AST.Param{} = param, idx} ->
      cond do
        idx < length(args) ->
          Scope.put(scope, param.name, Enum.at(args, idx))

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
    case Map.fetch(Heap.deref(ref), String.downcase(name)) do
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
    case Map.fetch(map, String.downcase(name)) do
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

  # Honor Lucee's full-null-support setting: with it off (Signal's default),
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
    case Map.fetch(map, key) do
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

  @spec resolve_var(String.t(), Env.t()) :: any()
  defp resolve_var(name, env) do
    down = String.downcase(name)

    cond do
      down == "cfc" ->
        %Namespace{base: "cfc"}

      down in ["arguments", "local", "variables"] ->
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

  @spec eval_args([tuple()], Env.t()) :: [any()]
  defp eval_args(args, env), do: Enum.map(args, &eval(&1, env))

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

  @spec instantiate_path(String.t(), [any()], Env.t()) :: Instance.t()
  defp instantiate_path(path, args, env) do
    component = Loader.load(path, env.ctx)
    instance = instantiate(component, path, env.ctx)

    # If a constructor with args is needed later, route through init here.
    if args != [] and function_named(component, "init") do
      _ = call_instance_method(instance, "init", args, env.ctx)
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
