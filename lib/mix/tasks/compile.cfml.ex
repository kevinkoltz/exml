defmodule Mix.Tasks.Compile.Cfml do
  @shortdoc "Validate .cfm/.cfc files ahead of time, failing the build on errors"

  @moduledoc """
  A Mix compiler that scans configured directories for `.cfm`/`.cfc` files and
  validates them with `ExML.CFScript.Validator`, so invalid CFML is caught **at
  build time** instead of crashing lazily at runtime.

  Add it to the host project's compilers (typically only in the envs where the
  `:exml` dependency is present) and point it at the directories to scan:

      # mix.exs
      compilers: Mix.compilers() ++ [:cfml]

      # config/config.exs (or per-env)
      config :exml, :validate,
        paths: ["lib/signal_web"],
        allow: ["cfhttp"]            # optional project-wide unsupported allow-list

  Every `.cfm`/`.cfc` under `:paths` is validated. A `:syntax` diagnostic (a file
  that doesn't parse) is always an error; an `:unsupported` diagnostic (a
  not-yet-implemented tag/attribute) is an error unless allow-listed via `:allow`
  or an inline `@exml-allow` directive in the file. Any error fails `mix compile`.
  """

  use Mix.Task.Compiler

  @compiler_name "cfml"

  @impl Mix.Task.Compiler
  def run(_argv) do
    {paths, opts} = config()
    diagnostics = collect(paths, opts)

    Enum.each(diagnostics, &print/1)

    if Enum.any?(diagnostics, &(&1.severity == :error)) do
      {:error, diagnostics}
    else
      {:noop, diagnostics}
    end
  end

  @impl Mix.Task.Compiler
  def manifests, do: []

  @doc """
  Validate every `.cfm`/`.cfc` under `paths` and return
  `Mix.Task.Compiler.Diagnostic` structs. The pure core of `run/1` — call it
  directly in tests.
  """
  @spec collect([String.t()], keyword()) :: [Mix.Task.Compiler.Diagnostic.t()]
  def collect(paths, opts \\ []) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{cfm,cfc}")))
    |> Enum.flat_map(&validate_file(&1, opts))
    |> Enum.map(&to_compiler_diagnostic/1)
  end

  @spec validate_file(String.t(), keyword()) :: [ExML.CFScript.Validator.diagnostic()]
  defp validate_file(file, opts) do
    source = File.read!(file)

    case Path.extname(file) do
      ".cfm" -> ExML.CFScript.validate_cfm(source, file, opts)
      ".cfc" -> ExML.CFScript.validate_cfc(source, file, opts)
      _ -> []
    end
  end

  @spec config() :: {[String.t()], keyword()}
  defp config do
    validate = Application.get_env(:exml, :validate, [])
    {Keyword.get(validate, :paths, []), [allow: Keyword.get(validate, :allow, [])]}
  end

  @spec to_compiler_diagnostic(ExML.CFScript.Validator.diagnostic()) ::
          Mix.Task.Compiler.Diagnostic.t()
  defp to_compiler_diagnostic(%{severity: severity, file: file, line: line, message: message}) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: @compiler_name,
      file: Path.expand(file),
      position: line || 0,
      severity: severity,
      message: message,
      details: nil
    }
  end

  @spec print(Mix.Task.Compiler.Diagnostic.t()) :: :ok
  defp print(%{severity: severity, file: file, position: line, message: message}) do
    label = if severity == :error, do: "error", else: "warning"
    location = Path.relative_to_cwd(file) <> if(line in [0, nil], do: "", else: ":#{line}")
    output = "cfml #{label}: #{location}: #{message}"

    if severity == :error,
      do: Mix.shell().error(output),
      else: Mix.shell().info(output)
  end
end
