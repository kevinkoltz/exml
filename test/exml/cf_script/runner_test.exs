defmodule ExML.CFScript.RunnerTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()
  @spec_path Path.join(__DIR__, "../../fixtures/specs/common_spec.cfc") |> Path.expand()

  test "runs the common.capitalize spec to a passing summary" do
    summary = Runner.run_spec_file(@spec_path, cfc_root: @cfc_root)

    assert summary.total == 2
    assert summary.passed == 2
    assert summary.failed == 0

    assert [
             %{status: :pass, group: "common.capitalize", description: "capitalizes" <> _},
             %{status: :pass, group: "common.capitalize", description: "returns empty" <> _}
           ] = summary.results
  end

  test "a failing assertion is reported as a failure, not an exception" do
    source = ~s"""
    component {
      function run() {
        common = new cfc.common();
        describe("capitalize", function() {
          it("wrong expectation", function() {
            assert_equal(common.capitalize("hello"), "WRONG");
          });
        });
      }
    }
    """

    summary = Runner.run_spec_source(source, "inline_spec.cfc", cfc_root: @cfc_root)

    assert summary.failed == 1
    assert [%{status: :fail, message: message}] = summary.results
    assert message =~ "Expected WRONG but got Hello"
  end
end
