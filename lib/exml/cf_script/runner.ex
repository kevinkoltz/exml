defmodule ExML.CFScript.Runner do
  @moduledoc """
  Runs a CFML test spec through the cfscript interpreter.

  The spec's `describe`/`it`/`xit`/`assert_*` calls resolve to native Elixir
  functions (registered here) rather than the HTML-emitting
  `test/test_framework.cfc`, so results are collected as plain data. Everything
  else — `new cfc.foo()`, method calls, BIFs — is interpreted from the real
  `.cfc` sources under `cfc_root`.
  """

  alias ExML.CFScript.{CFException, Context, Interpreter, Loader, Reporter, Scope, Value}
  alias ExML.CFScript.Value.Native

  @type result :: Reporter.result()
  @type summary :: %{
          results: [result()],
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Run the spec file at `spec_path`.

  Options:
    * `:cfc_root` (required) — directory the `cfc.*` mapping resolves against.
    * `:null_support` (default `false`) — Lucee full-null-support mode. Off (the
      common default) makes missing-key access raise; on yields null.
    * `:scopes` — seed values for the predefined CFML scopes, e.g.
      `%{"request" => %{"db_name" => "appdb"}, "application" => %{...}}`.
      These would normally be set by the Application.cfc request lifecycle, which
      the interpreter does not run.
    * `:query_executor` — `(sql, params) -> %{columns:, rows:}` backing
      `<cfquery>`/`queryExecute`. Pass `:stub` to use a no-op that returns an
      empty result set without touching any database — useful for exercising the
      language without a live DB. Omitted entirely, a query raises.
  """
  @spec run_spec_file(String.t(), keyword()) :: summary()
  def run_spec_file(spec_path, opts) do
    spec_path
    |> File.read!()
    |> run_spec_source(spec_path, opts)
  end

  @doc "Run spec source directly (used by tests). See `run_spec_file/2` for options."
  @spec run_spec_source(String.t(), String.t(), keyword()) :: summary()
  def run_spec_source(source, label, opts) do
    cfc_root = Keyword.fetch!(opts, :cfc_root)
    {:ok, cache} = Agent.start_link(fn -> %{} end)

    ctx = %Context{
      cfc_root: cfc_root,
      cache: cache,
      natives: build_natives(),
      null_support: Keyword.get(opts, :null_support, false),
      query_executor: resolve_executor(Keyword.get(opts, :query_executor)),
      scopes: build_scopes(Keyword.get(opts, :scopes, %{}))
    }

    try do
      component = Loader.parse_source(source, label)
      instance = Interpreter.instantiate(component, label, ctx)

      Reporter.start()

      try do
        Interpreter.call_instance_method(instance, "run", [], ctx)
      rescue
        e -> Reporter.record(:error, "run()", Exception.message(e))
      catch
        :throw, value -> Reporter.record(:error, "run()", "uncaught throw: #{inspect(value)}")
      end

      summarize(Reporter.results())
    after
      Agent.stop(cache)
    end
  end

  # Create a fresh mutable Scope for each predefined CFML scope, seeded from the
  # host-provided `:scopes` map (e.g. %{"request" => %{"db_name" => "..."}}).
  @spec build_scopes(map()) :: %{optional(String.t()) => reference()}
  defp build_scopes(seed) do
    Map.new(Interpreter.predefined_scopes(), fn name ->
      {name, Scope.new(Map.get(seed, name, %{}))}
    end)
  end

  # `:stub` -> a no-op executor returning an empty result (no DB). Any other
  # value (a function or nil) passes through unchanged.
  @spec resolve_executor(any()) :: (String.t(), any() -> map()) | nil
  defp resolve_executor(:stub), do: fn _sql, _params -> %{columns: [], rows: []} end
  defp resolve_executor(other), do: other

  @spec summarize([result()]) :: summary()
  defp summarize(results) do
    passed = Enum.count(results, &(&1.status == :pass))
    failed = length(results) - passed
    %{results: results, passed: passed, failed: failed, total: length(results)}
  end

  ## Native test-framework functions

  @spec build_natives() :: %{optional(String.t()) => Native.t()}
  defp build_natives do
    %{
      "describe" => native("describe", &describe/2),
      "it" => native("it", &it/2),
      "xit" => native("xit", &xit/2),
      "assert_equal" => native("assert_equal", &assert_equal/2),
      "assert_not_equal" => native("assert_not_equal", &assert_not_equal/2),
      "assert_true" => native("assert_true", &assert_true/2),
      "assert_false" => native("assert_false", &assert_false/2),
      "assert_match" => native("assert_match", &assert_match/2),
      "assert_throws" => native("assert_throws", &assert_throws/2)
    }
  end

  @spec native(String.t(), (list(), term() -> any())) :: Native.t()
  defp native(name, fun), do: %Native{name: name, fun: fun}

  defp describe([description, body | _], env) do
    Reporter.push_group(Value.to_str(description))

    try do
      Interpreter.invoke(body, [], env)
    rescue
      e -> Reporter.record(:error, "describe(#{Value.to_str(description)})", Exception.message(e))
    after
      Reporter.pop_group()
    end

    nil
  end

  defp it([description, body | _], env) do
    desc = Value.to_str(description)

    try do
      Interpreter.invoke(body, [], env)
      Reporter.record(:pass, desc)
    rescue
      e in CFException -> Reporter.record(:fail, desc, e.message)
      e -> Reporter.record(:error, desc, Exception.message(e))
    catch
      :throw, value -> Reporter.record(:error, desc, "uncaught throw: #{inspect(value)}")
    end

    nil
  end

  defp xit([description | _], _env) do
    Reporter.record(:pass, "#{Value.to_str(description)} (skipped)")
    nil
  end

  defp assert_equal([actual, expected | rest], _env) do
    unless Value.equals?(actual, expected) do
      raise CFException,
        cf_type: "AssertionError",
        message:
          "Expected #{Value.display(expected)} but got #{Value.display(actual)}" <>
            suffix(rest)
    end

    nil
  end

  defp assert_not_equal([actual, expected | rest], _env) do
    if Value.equals?(actual, expected) do
      raise CFException,
        cf_type: "AssertionError",
        message:
          "Expected value to not equal #{Value.display(expected)} but it did" <> suffix(rest)
    end

    nil
  end

  defp assert_true([condition | rest], _env) do
    unless Value.truthy?(condition) do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected true but got #{Value.display(condition)}" <> suffix(rest)
    end

    nil
  end

  defp assert_false([condition | rest], _env) do
    if Value.truthy?(condition) do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected false but got #{Value.display(condition)}" <> suffix(rest)
    end

    nil
  end

  defp assert_match([actual, pattern | rest], _env) do
    str = Value.display(actual)

    matched =
      case Regex.compile(Value.to_str(pattern)) do
        {:ok, regex} -> Regex.match?(regex, str)
        {:error, _} -> false
      end

    unless matched do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected '#{str}' to match /#{Value.to_str(pattern)}/" <> suffix(rest)
    end

    nil
  end

  # assert_throws(callback [, expected_type [, expected_message]]): runs the
  # callback, requires it to throw, and (optionally) checks the exception type
  # and that its message contains expected_message.
  defp assert_throws([callback | rest], env) do
    expected_type = Value.to_str(Enum.at(rest, 0, ""))
    expected_message = Value.to_str(Enum.at(rest, 1, ""))

    case run_callback(callback, env) do
      :no_throw ->
        raise CFException,
          cf_type: "AssertionError",
          message: "Expected an exception but none was thrown"

      {:threw, type, message} ->
        check_throw_type(expected_type, type)
        check_throw_message(expected_message, message)
        nil
    end
  end

  @spec run_callback(any(), term()) :: :no_throw | {:threw, String.t(), String.t()}
  defp run_callback(callback, env) do
    Interpreter.invoke(callback, [], env)
    :no_throw
  rescue
    e in CFException -> {:threw, e.cf_type, e.message}
    e -> {:threw, "Application", Exception.message(e)}
  end

  defp check_throw_type("", _type), do: :ok

  defp check_throw_type(expected, type) do
    if String.downcase(type) != String.downcase(expected) do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected exception of type #{expected} but got #{type}"
    end
  end

  defp check_throw_message("", _message), do: :ok

  defp check_throw_message(expected, message) do
    unless String.contains?(message, expected) do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected exception message containing '#{expected}' but got '#{message}'"
    end
  end

  @spec suffix([any()]) :: String.t()
  defp suffix([message | _]) do
    case Value.to_str(message) do
      "" -> ""
      text -> " - #{text}"
    end
  end

  defp suffix(_), do: ""
end
