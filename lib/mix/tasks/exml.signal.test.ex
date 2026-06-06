defmodule Mix.Tasks.Exml.Signal.Test do
  @shortdoc "Run Signal CFML test specs through the ExML cfscript interpreter"

  @moduledoc """
  Run one or more Signal CFML test specs through the ExML cfscript interpreter.

      mix exml.signal.test SPEC... --cfc-root PATH [--spec-root PATH]

  ## Arguments

  `SPEC` is either a path to a `.cfc` spec or a bare spec name (resolved under
  `--spec-root`, with a `.cfc`/`_spec.cfc` suffix added if missing).

  ## Options

    * `--cfc-root`  (required) directory the `cfc.*` component mapping resolves against
    * `--spec-root` directory bare spec names are resolved against

  ## Examples

      mix exml.signal.test common_spec \\
        --cfc-root ../signal/cfc \\
        --spec-root ../signal/test/specs

      mix exml.signal.test ../signal/test/specs/common_spec.cfc --cfc-root ../signal/cfc
  """

  use Mix.Task

  alias ExML.CFScript.Runner

  @switches [cfc_root: :string, spec_root: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, specs, _invalid} = OptionParser.parse(argv, switches: @switches)

    cfc_root = opts[:cfc_root] || Mix.raise("--cfc-root is required")

    if specs == [] do
      Mix.raise("provide at least one spec path or name")
    end

    results =
      Enum.map(specs, fn spec ->
        path = resolve_spec(spec, opts[:spec_root])
        Mix.shell().info("\n\e[1m== #{path}\e[0m")
        summary = Runner.run_spec_file(path, cfc_root: cfc_root)
        print_summary(summary)
        summary
      end)

    failed = Enum.sum(Enum.map(results, & &1.failed))

    if failed > 0 do
      Mix.raise("#{failed} failing assertion(s)")
    end
  end

  @spec resolve_spec(String.t(), String.t() | nil) :: String.t()
  defp resolve_spec(spec, spec_root) do
    cond do
      File.exists?(spec) ->
        spec

      spec_root && File.exists?(Path.join(spec_root, spec)) ->
        Path.join(spec_root, spec)

      spec_root && File.exists?(Path.join(spec_root, spec <> ".cfc")) ->
        Path.join(spec_root, spec <> ".cfc")

      spec_root && File.exists?(Path.join(spec_root, spec <> "_spec.cfc")) ->
        Path.join(spec_root, spec <> "_spec.cfc")

      true ->
        Mix.raise("could not find spec: #{spec}")
    end
  end

  @spec print_summary(Runner.summary()) :: :ok
  defp print_summary(%{results: results} = summary) do
    Enum.each(results, &print_result/1)

    color = if summary.failed == 0, do: "\e[32m", else: "\e[31m"

    Mix.shell().info(
      "#{color}#{summary.passed}/#{summary.total} passed, #{summary.failed} failed\e[0m"
    )

    :ok
  end

  @spec print_result(Runner.result()) :: :ok
  defp print_result(result) do
    prefix = if result.group == "", do: "", else: result.group <> " › "

    line =
      case result.status do
        :pass -> "  \e[32m✓\e[0m #{prefix}#{result.description}"
        :fail -> "  \e[31m✗ #{prefix}#{result.description}\e[0m — #{result.message}"
        :error -> "  \e[31m! #{prefix}#{result.description}\e[0m — #{result.message}"
      end

    Mix.shell().info(line)
    :ok
  end
end
