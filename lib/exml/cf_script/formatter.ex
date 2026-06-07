defmodule ExML.CFScript.Formatter do
  @moduledoc """
  Renders a `ExML.CFScript.Runner` summary as a modern, colorized test report:
  results grouped by `describe`, a checkmark/cross per test, and — for failures
  and errors — a detail block with the exception type, message, `detail`, and a
  CFML call-stack backtrace.

  `format/2` returns a string; the caller prints it. Colour is auto-detected
  (`IO.ANSI.enabled?/0`) and can be forced with `color: true | false`.
  """

  alias ExML.CFScript.Reporter

  @check "✓"
  @cross "✗"
  @skip "○"
  @bullet "●"

  @doc "Render a run summary (`%{results:, passed:, failed:, total:}`) as a report."
  @spec format(map(), keyword()) :: String.t()
  def format(summary, opts \\ []) do
    color = Keyword.get(opts, :color, IO.ANSI.enabled?())

    [
      results_tree(summary.results, color),
      failures_section(summary.results, color),
      footer(summary, color)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  ## Results tree (grouped by describe path)

  @spec results_tree([Reporter.result()], boolean()) :: String.t()
  defp results_tree(results, color) do
    results
    |> chunk_by_group()
    |> Enum.map_join("\n", fn {group, items} ->
      header = paint(group, [:bright, :cyan], color)
      lines = Enum.map_join(items, "\n", &test_line(&1, color))
      "  #{header}\n#{lines}"
    end)
  end

  # Group consecutive results by their `group`, preserving first-seen order.
  @spec chunk_by_group([Reporter.result()]) :: [{String.t(), [Reporter.result()]}]
  defp chunk_by_group(results) do
    results
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn [%{group: g} | _] = items -> {blank_to_root(g), items} end)
  end

  @spec test_line(Reporter.result(), boolean()) :: String.t()
  defp test_line(%{status: :pass, description: desc}, color) do
    if skipped?(desc) do
      "    #{paint(@skip, [:yellow], color)} #{paint(desc, [:faint], color)}"
    else
      "    #{paint(@check, [:green], color)} #{paint(desc, [:faint], color)}"
    end
  end

  defp test_line(%{status: status, description: desc}, color) when status in [:fail, :error] do
    "    #{paint(@cross, [:red], color)} #{paint(desc, [:red], color)}"
  end

  ## Failures / errors detail section

  @spec failures_section([Reporter.result()], boolean()) :: String.t()
  defp failures_section(results, color) do
    failures = Enum.filter(results, &(&1.status in [:fail, :error]))

    case failures do
      [] -> ""
      _ -> "\n" <> Enum.map_join(failures, "\n\n", &failure_block(&1, color))
    end
  end

  @spec failure_block(Reporter.result(), boolean()) :: String.t()
  defp failure_block(result, color) do
    title = paint("#{@bullet} #{path(result)}", [:bright, :red], color)
    label = status_label(result, color)
    headline = "  #{title}\n    #{label} #{result.message}"

    [headline, detail_line(result, color), stack_lines(result, color)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec status_label(Reporter.result(), boolean()) :: String.t()
  defp status_label(%{status: :fail}, color), do: paint("ASSERTION", [:yellow, :bright], color)

  defp status_label(%{type: type}, color) when is_binary(type) and type != "",
    do: paint(type, [:red, :bright], color)

  defp status_label(_result, color), do: paint("ERROR", [:red, :bright], color)

  @spec detail_line(Reporter.result(), boolean()) :: String.t()
  defp detail_line(%{detail: d}, color) when is_binary(d) and d != "",
    do: "    #{paint(d, [:faint], color)}"

  defp detail_line(_result, _color), do: ""

  @spec stack_lines(Reporter.result(), boolean()) :: String.t()
  defp stack_lines(%{stack: stack}, color) when is_list(stack) and stack != [] do
    Enum.map_join(stack, "\n", fn frame ->
      "      #{paint("at #{frame.source}.#{frame.function}#{at_line(frame)}", [:faint], color)}"
    end)
  end

  defp stack_lines(_result, _color), do: ""

  @spec at_line(map()) :: String.t()
  defp at_line(%{line: line}) when is_integer(line), do: " (line #{line})"
  defp at_line(_frame), do: ""

  ## Footer

  @spec footer(map(), boolean()) :: String.t()
  defp footer(summary, color) do
    parts =
      [
        {summary.passed, "passed", :green},
        {summary.failed, "failed", :red},
        {summary.total, "total", :faint}
      ]
      |> Enum.map(fn {n, label, c} -> paint("#{n} #{label}", [c], color) end)
      |> Enum.join(paint(" · ", [:faint], color))

    banner =
      if summary.failed == 0,
        do: paint(" PASS ", [:green_background, :black, :bright], color),
        else: paint(" FAIL ", [:red_background, :white, :bright], color)

    "\n  #{banner}  #{parts}"
  end

  ## Helpers

  @spec path(Reporter.result()) :: String.t()
  defp path(%{group: "", description: desc}), do: desc
  defp path(%{group: group, description: desc}), do: "#{group} › #{desc}"

  @spec blank_to_root(String.t()) :: String.t()
  defp blank_to_root(""), do: "(root)"
  defp blank_to_root(group), do: group

  @spec skipped?(String.t()) :: boolean()
  defp skipped?(desc), do: String.ends_with?(desc, "(skipped)")

  @spec paint(String.t(), [atom()], boolean()) :: String.t()
  defp paint(text, _codes, false), do: text

  defp paint(text, codes, true) do
    prefix = codes |> Enum.map(&apply(IO.ANSI, &1, [])) |> Enum.join()
    prefix <> text <> IO.ANSI.reset()
  end
end
