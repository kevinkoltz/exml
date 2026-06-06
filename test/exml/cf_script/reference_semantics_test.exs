defmodule ExML.CFScript.ReferenceSemanticsTest do
  @moduledoc """
  Lucee parity for reference-type arrays/structs: aliasing, in-place mutation,
  member-chaining returns, mutation through function arguments, and duplicate/3
  breaking the reference.
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

  test "array aliasing: b = a shares the same array" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("shared reference", function() {
                   a = [1, 2];
                   b = a;
                   arrayAppend(b, 3);
                   assert_equal(arrayToList(a), "1,2,3");
                 });
               });
               """)
             )
  end

  test "in-place mutation via member and index assignment" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("mutates", function() {
                   a = [1, 2];
                   a.append(3);
                   a[1] = 9;
                   assert_equal(arrayToList(a), "9,2,3");
                 });
               });
               """)
             )
  end

  test "arrayAppend returns true; member .append returns the array (chaining)" do
    assert 2 ==
             passing(
               run("""
               describe("g", function() {
                 it("bare returns boolean", function() {
                   a = [1];
                   assert_true(arrayAppend(a, 2));
                 });
                 it("member chains", function() {
                   a = [1];
                   a.append(2).append(3);
                   assert_equal(arrayToList(a), "1,2,3");
                 });
               });
               """)
             )
  end

  test "struct mutation and aliasing" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("shared struct", function() {
                   s = {a: 1};
                   t = s;
                   t.b = 2;
                   s["c"] = 3;
                   assert_true(structCount(s) == 3);
                   assert_equal(t.c, 3);
                 });
               });
               """)
             )
  end

  test "mutation through a function argument is visible to the caller" do
    summary =
      Runner.run_spec_source(
        """
        component {
          function pushItem(arr, value) { arrayAppend(arguments.arr, arguments.value); }
          function run() {
            describe("g", function() {
              it("arg mutation propagates", function() {
                xs = [1];
                pushItem(xs, 2);
                assert_equal(arrayToList(xs), "1,2");
              });
            });
          }
        }
        """,
        "inline.cfc",
        cfc_root: @cfc_root
      )

    assert summary.failed == 0
    assert summary.passed == 1
  end

  test "duplicate breaks the reference (deep copy)" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("independent copy", function() {
                   a = [1, 2];
                   b = duplicate(a);
                   arrayAppend(b, 3);
                   assert_equal(arrayToList(a), "1,2");
                   assert_equal(arrayToList(b), "1,2,3");
                 });
               });
               """)
             )
  end

  test "higher-order map/filter return new arrays, leaving the original intact" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("non-mutating", function() {
                   a = [1, 2, 3];
                   doubled = a.map(function(n) { return n * 2; });
                   assert_equal(arrayToList(a), "1,2,3");
                   assert_equal(arrayToList(doubled), "2,4,6");
                 });
               });
               """)
             )
  end
end
