defmodule ExML.CFScript.NullSupportTest do
  @moduledoc """
  Lucee's "full null support" setting changes how missing keys behave. The codebase under test
  runs with it OFF (the default here): reading a missing struct key throws.
  Turning it on yields null instead.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body, opts) do
    source = "component { function run() { #{body} } }"
    Runner.run_spec_source(source, "inline.cfc", Keyword.put(opts, :cfc_root, @cfc_root))
  end

  test "with null support OFF (default), missing struct key access throws" do
    summary =
      run(
        """
        describe("g", function() {
          it("missing key throws", function() {
            s = {a: 1};
            x = s.missing;
          });
        });
        """,
        []
      )

    assert summary.failed == 1
    assert [%{status: status, message: message}] = summary.results
    assert status in [:fail, :error]
    assert message =~ "doesn't exist"
  end

  test "with null support ON, missing struct key yields null" do
    summary =
      run(
        """
        describe("g", function() {
          it("missing key is null", function() {
            s = {a: 1};
            assert_true(isNull(s.missing));
          });
        });
        """,
        null_support: true
      )

    assert summary.failed == 0
    assert summary.passed == 1
  end

  test "existing keys still read in both modes" do
    body =
      ~s|describe("g", function() { it("reads", function() { s = {a: 1}; assert_equal(s.a, 1); }); });|

    assert run(body, []).passed == 1
    assert run(body, null_support: true).passed == 1
  end
end
