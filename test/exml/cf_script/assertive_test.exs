defmodule ExML.CFScript.AssertiveTest do
  @moduledoc """
  "Let it crash" coverage: unsupported syntax, tags, and attributes load (so the
  rest of the component works) but raise a loud, specific `exml.unsupported`
  error if reached — rather than being silently dropped or ignored.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  # Call `cfc.assertive`.`fn`() inside a try/catch and report {type, message}.
  defp call(fn_name) do
    summary =
      Runner.run_spec_source(
        """
        component {
          function run() {
            a = new cfc.assertive();
            describe("g", function() {
              it("t", function() {
                try { a.#{fn_name}(); thrown = ""; }
                catch (any e) { thrown = e.type & "|" & e.message; }
                assert_true(true);
              });
            });
          }
        }
        """,
        "inline.cfc",
        cfc_root: @cfc_root
      )

    # surface the caught info via the assertion message channel isn't available,
    # so re-run uncaught to capture the error result directly:
    uncaught =
      Runner.run_spec_source(
        "component { function run() { a = new cfc.assertive(); a.#{fn_name}(); } }",
        "inline.cfc",
        cfc_root: @cfc_root
      )

    assert summary.failed == 0, "wrapper spec failed: #{inspect(summary.results)}"
    hd(uncaught.results)
  end

  test "a recoverable parse error mid-body loads the function and raises if reached" do
    result = call("recovers")
    # not "has no function" — the function loaded despite the bad statement
    assert result.type == "exml.unsupported"
    assert result.message =~ "unsupported syntax"
  end

  test "an unknown tag attribute raises a specific error naming the attribute" do
    result = call("bad_attr")
    assert result.type == "exml.unsupported"
    assert result.message =~ "cfquery: unsupported attribute [frobnicate]"
  end

  test "an unsupported tag raises an error naming the tag" do
    result = call("unsupported_tag")
    assert result.type == "exml.unsupported"
    assert result.message =~ "unsupported CFML tag cffile"
  end
end
