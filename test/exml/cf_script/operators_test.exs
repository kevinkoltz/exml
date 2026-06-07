defmodule ExML.CFScript.OperatorsTest do
  @moduledoc "CFML word operators evaluated by the interpreter (e.g. `contains`)."
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

  test "contains is a case-insensitive infix substring test (Lucee OP_DEC_CT)" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("matches case-insensitively", function() {
                   assert_true("Hello World" contains "world");
                   assert_true("abcdef" contains "cde");
                   assert_false("abc" contains "xyz");
                 });
               });
               """)
             )
  end

  test "contains composes inside conditions and with other operators" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("works in expressions", function() {
                   s = "specialCharacter found";
                   assert_equal(s contains "special" ? "yes" : "no", "yes");
                   assert_true(s contains "Special" and len(s) > 0);
                 });
               });
               """)
             )
  end

  test "the contains() function is unaffected by the operator" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("function call still parses", function() {
                   assert_true(contains("Hello", "ell"));
                 });
               });
               """)
             )
  end
end
