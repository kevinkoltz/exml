defmodule ExML.CFScript.LocalmodeTest do
  @moduledoc """
  localmode behavior: classic functions leak unscoped assignments into the
  shared `variables` scope; localmode=\"modern\" keeps them in `local`. An
  explicit `var` is always local.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body) do
    Runner.run_spec_source("component { function run() { #{body} } }", "inline.cfc",
      cfc_root: @cfc_root
    )
  end

  defp passing(summary) do
    assert summary.failed == 0, "unexpected failures: #{inspect(summary.results)}"
    summary.passed
  end

  test "classic leaks to variables; modern and var stay local" do
    assert 1 ==
             passing(
               run("""
               describe("localmode", function() {
                 it("scopes unscoped assignments", function() {
                   s = new cfc.scopes();

                   s.classic_set();
                   assert_true(s.variables_has("leaked"));

                   s.modern_set();
                   assert_false(s.variables_has("contained"));

                   s.var_set();
                   assert_false(s.variables_has("explicit"));
                 });
               });
               """)
             )
  end
end
