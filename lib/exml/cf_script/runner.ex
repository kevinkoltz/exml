defmodule ExML.CFScript.Runner do
  @moduledoc """
  Runs a Signal CFML test spec through the cfscript interpreter.

  The spec's `describe`/`it`/`xit`/`assert_*` calls resolve to native Elixir
  functions (registered here) rather than the HTML-emitting
  `test/test_framework.cfc`, so results are collected as plain data. Everything
  else — `new cfc.foo()`, method calls, BIFs — is interpreted from the real
  `.cfc` sources under `cfc_root`.
  """

  alias ExML.CFScript.{CFException, Context, Interpreter, Loader, Reporter, Value}
  alias ExML.CFScript.Value.Native

  @type result :: Reporter.result()
  @type summary :: %{results: [result()], passed: non_neg_integer(), failed: non_neg_integer(), total: non_neg_integer()}

  @doc """
  Run the spec file at `spec_path`.

  Options:
    * `:cfc_root` (required) — directory the `cfc.*` mapping resolves against.
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

    ctx = %Context{cfc_root: cfc_root, cache: cache, natives: build_natives()}

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
      "assert_match" => native("assert_match", &assert_match/2)
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
          "Expected #{Value.to_str(expected)} but got #{Value.to_str(actual)}" <>
            suffix(rest)
    end

    nil
  end

  defp assert_not_equal([actual, expected | rest], _env) do
    if Value.equals?(actual, expected) do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected value to not equal #{Value.to_str(expected)} but it did" <> suffix(rest)
    end

    nil
  end

  defp assert_true([condition | rest], _env) do
    unless Value.truthy?(condition) do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected true but got #{Value.to_str(condition)}" <> suffix(rest)
    end

    nil
  end

  defp assert_false([condition | rest], _env) do
    if Value.truthy?(condition) do
      raise CFException,
        cf_type: "AssertionError",
        message: "Expected false but got #{Value.to_str(condition)}" <> suffix(rest)
    end

    nil
  end

  defp assert_match([actual, pattern | rest], _env) do
    str = Value.to_str(actual)

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

  @spec suffix([any()]) :: String.t()
  defp suffix([message | _]) do
    case Value.to_str(message) do
      "" -> ""
      text -> " - #{text}"
    end
  end

  defp suffix(_), do: ""
end
