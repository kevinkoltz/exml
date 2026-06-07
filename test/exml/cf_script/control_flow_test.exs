defmodule ExML.CFScript.ControlFlowTest do
  @moduledoc "for / for-in / while loops, increments, compound assignment, and arrow functions."
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

  test "C-style for with ++ and compound assignment" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("sums 1..5", function() {
                   total = 0;
                   for (i = 1; i <= 5; i++) { total += i; }
                   assert_equal(total, 15);
                 });
               });
               """)
             )
  end

  test "for-in over an array" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("concatenates", function() {
                   out = "";
                   for (x in ["a", "b", "c"]) { out &= x; }
                   assert_equal(out, "abc");
                 });
               });
               """)
             )
  end

  test "for-in over a struct iterates keys" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("counts keys", function() {
                   s = {a: 1, b: 2, c: 3};
                   n = 0;
                   for (k in s) { n++; }
                   assert_equal(n, 3);
                 });
               });
               """)
             )
  end

  test "while loop" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("doubles until >= 100", function() {
                   x = 1;
                   while (x < 100) { x = x * 2; }
                   assert_equal(x, 128);
                 });
               });
               """)
             )
  end

  test "arrow functions: block body and implicit-return expression" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("map/filter/reduce with arrows", function() {
                   nums = [1, 2, 3, 4];
                   evens = nums.filter((n) => n % 2 == 0);
                   assert_equal(arrayToList(evens), "2,4");
                   doubled = nums.map((n) => { return n * 2; });
                   assert_equal(arrayToList(doubled), "2,4,6,8");
                   total = nums.reduce((acc, n) => acc + n, 0);
                   assert_equal(total, 10);
                 });
               });
               """)
             )
  end

  test "single-parameter arrow without parens" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("works", function() {
                   xs = [1, 2, 3];
                   big = xs.filter(n => n > 1);
                   assert_equal(arrayToList(big), "2,3");
                 });
               });
               """)
             )
  end
end
