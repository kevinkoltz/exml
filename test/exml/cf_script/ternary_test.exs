defmodule ExML.CFScript.TernaryTest do
  @moduledoc "Ternary (`?:`) and elvis (`?:` null-coalescing) operators."
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

  test "ternary picks the branch by the condition" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("chooses", function() {
                   x = 5;
                   assert_equal(x > 3 ? "big" : "small", "big");
                   assert_equal(x < 3 ? "big" : "small", "small");
                 });
               });
               """)
             )
  end

  test "ternary nests right-associatively" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("grades", function() {
                   n = 75;
                   grade = n >= 90 ? "A" : n >= 70 ? "B" : "C";
                   assert_equal(grade, "B");
                 });
               });
               """)
             )
  end

  test "elvis returns the left value when it is defined and non-null" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("keeps defined", function() {
                   y = "set";
                   assert_equal(y ?: "fallback", "set");
                 });
               });
               """)
             )
  end

  test "elvis falls back when the left is an undefined variable" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("uses fallback", function() {
                   assert_equal(missing ?: "fallback", "fallback");
                 });
               });
               """)
             )
  end

  test "elvis does not fall back for an empty string (only null/undefined)" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("empty is not null", function() {
                   a = "";
                   assert_equal(a ?: "fallback", "");
                 });
               });
               """)
             )
  end
end
