defmodule ExML.CFScript.LexicalScopeTest do
  @moduledoc """
  Closures capture the locals of their defining function, multi-segment
  component paths resolve through package namespaces, and component instances
  support index access (`inst["x"]`).
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run_source(source) do
    Runner.run_spec_source(source, "inline.cfc", cfc_root: @cfc_root)
  end

  defp run(body) do
    run_source("component { function run() { #{body} } }")
  end

  defp passing(summary) do
    assert summary.failed == 0, "unexpected failures: #{inspect(summary.results)}"
    summary.passed
  end

  test "a closure reads a local of its enclosing localmode function" do
    # `msg` lands in run()'s local scope (localmode); the deferred it() closure
    # must still see it lexically.
    summary =
      run_source("""
      component {
        function run() localmode=true {
          msg = "hi from enclosing local";
          describe("g", function() {
            it("captures the enclosing local", function() {
              assert_equal(msg, "hi from enclosing local");
            });
          });
        }
      }
      """)

    assert summary.failed == 0, "unexpected failures: #{inspect(summary.results)}"
    assert summary.passed == 1
  end

  test "a multi-segment component path resolves a static method through a package" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("calls a packaged static method", function() {
                   assert_equal(cfc.pkg.thing::tag(), "PKG");
                 });
               });
               """)
             )
  end

  test "component instances support index get/set on public fields" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("reads and writes via index", function() {
                   t = new cfc.pkg.thing();
                   assert_equal(t["label"], "thing");
                   assert_equal(t.read_label(), "thing");
                   t["label"] = "renamed";
                   assert_equal(t["label"], "renamed");
                 });
               });
               """)
             )
  end
end
