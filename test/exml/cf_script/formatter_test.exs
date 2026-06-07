defmodule ExML.CFScript.FormatterTest do
  @moduledoc "Backtrace capture on thrown exceptions and the modern report rendering."
  use ExUnit.Case, async: true

  alias ExML.CFScript.{Formatter, Runner}

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  # A spec that throws from two functions deep, fails an assertion, and skips one.
  defp mixed_summary do
    Runner.run_spec_source(
      """
      component {
        function inner() { throw(message="kaboom", type="MyError", detail="extra context"); }
        function boom() { return inner(); }
        function run() {
          describe("widgets", function() {
            it("passes", function() { assert_equal(1, 1); });
            it("explodes", function() { boom(); });
            it("mismatches", function() { assert_equal(2, 3); });
            xit("todo", function() {});
          });
        }
      }
      """,
      "widget_spec.cfc",
      cfc_root: @cfc_root
    )
  end

  describe "backtrace + error detail capture" do
    test "a thrown exception records type, detail, and a CFML call stack" do
      result =
        mixed_summary().results
        |> Enum.find(&(&1.description == "explodes"))

      assert result.status == :error
      assert result.type == "MyError"
      assert result.message == "kaboom"
      assert result.detail == "extra context"

      assert Enum.map(result.stack, & &1.function) == ["inner", "boom", "run"]
      assert Enum.all?(result.stack, &(&1.source == "widget_spec.cfc"))
      # statement-level lines: inner throws (2), boom calls inner (3), run reaches
      # boom() inside the `it` body (7).
      assert Enum.map(result.stack, & &1.line) == [2, 3, 7]
    end

    test "an assertion failure is a :fail with no backtrace" do
      result = mixed_summary().results |> Enum.find(&(&1.description == "mismatches"))
      assert result.status == :fail
      assert result.type == "AssertionError"
      assert result.stack == []
    end

    test "statement line is accurate through tag conversion (the <cfthrow> line)" do
      # tagthrow.cfc: <cfthrow> is on line 4 of the original tag-based source.
      summary =
        Runner.run_spec_source(
          ~S|component { function run() { new cfc.tagthrow().boom(); } }|,
          "inline.cfc",
          cfc_root: @cfc_root
        )

      [%{stack: stack}] = summary.results
      boom = Enum.find(stack, &(&1.function == "boom"))
      assert boom.source == "cfc.tagthrow"
      assert boom.line == 4
    end
  end

  describe "format/2" do
    test "renders groups, per-test marks, a detail block, and a footer (no color)" do
      report = Formatter.format(mixed_summary(), color: false)

      # grouped header + per-test marks
      assert report =~ "widgets"
      assert report =~ "✓ passes"
      assert report =~ "✗ explodes"
      assert report =~ "○ todo (skipped)"

      # failure detail block: type badge, message, detail, and backtrace
      assert report =~ "● widgets › explodes"
      assert report =~ "MyError kaboom"
      assert report =~ "extra context"
      assert report =~ "at widget_spec.cfc.inner (line 2)"
      assert report =~ "at widget_spec.cfc.boom (line 3)"

      # assertion failures are labelled distinctly
      assert report =~ "ASSERTION Expected 3 but got 2"

      # footer
      assert report =~ "FAIL"
      assert report =~ "2 passed · 2 failed · 4 total"
    end

    test "color: false emits no ANSI escapes" do
      refute Formatter.format(mixed_summary(), color: false) =~ "\e["
    end

    test "color: true emits ANSI escapes" do
      assert Formatter.format(mixed_summary(), color: true) =~ "\e["
    end

    test "an all-passing run shows a PASS banner" do
      summary =
        Runner.run_spec_source(
          ~S|component { function run() { describe("g", function() { it("ok", function() { assert_true(true); }); }); } }|,
          "ok_spec.cfc",
          cfc_root: @cfc_root
        )

      report = Formatter.format(summary, color: false)
      assert report =~ "PASS"
      assert report =~ "1 passed · 0 failed · 1 total"
    end
  end
end
