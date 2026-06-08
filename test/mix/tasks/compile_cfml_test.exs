defmodule Mix.Tasks.Compile.CfmlTest do
  @moduledoc """
  The `:cfml` Mix compiler core: scans a directory tree for `.cfm`/`.cfc`,
  validates each, and produces `Mix.Task.Compiler.Diagnostic`s so the build can
  fail on invalid CFML.
  """
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "../../fixtures/cfm_validate") |> Path.expand()

  defp for_file(diags, basename) do
    Enum.filter(diags, &(Path.basename(&1.file) == basename))
  end

  test "collect/2 validates every .cfm/.cfc under the path and flags errors" do
    diags = Mix.Tasks.Compile.Cfml.collect([@fixtures])

    # clean.cfm produces nothing
    assert for_file(diags, "clean.cfm") == []

    # bad_tag.cfm: unsupported <cffile> at line 2, an error
    assert [cffile] = for_file(diags, "bad_tag.cfm")
    assert cffile.severity == :error
    assert cffile.position == 2
    assert cffile.message =~ "cffile"
    assert cffile.compiler_name == "cfml"

    # allowed.cfm: same <cffile> but @exml-allow'd -> warning, not error
    assert [allowed] = for_file(diags, "allowed.cfm")
    assert allowed.severity == :warning

    # widget.cfc: only the dirty() function's <cfftp> is flagged
    assert [cfftp] = for_file(diags, "widget.cfc")
    assert cfftp.severity == :error
    assert cfftp.message =~ "cfftp"
  end

  test "the project-wide :allow option downgrades matching constructs" do
    diags = Mix.Tasks.Compile.Cfml.collect([@fixtures], allow: ["cffile", "cfftp"])

    assert Enum.all?(diags, &(&1.severity == :warning))
  end

  test "an empty path list yields no diagnostics" do
    assert Mix.Tasks.Compile.Cfml.collect([]) == []
  end
end
