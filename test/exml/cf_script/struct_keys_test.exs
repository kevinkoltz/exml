defmodule ExML.CFScript.StructKeysTest do
  @moduledoc """
  CFML struct key semantics: case-insensitive lookup but case-preserving
  iteration, plus javaCast/null handling with full-null-support off.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body, opts \\ []) do
    Runner.run_spec_source(
      "component { function run() { #{body} } }",
      "inline.cfc",
      Keyword.put(opts, :cfc_root, @cfc_root)
    )
  end

  defp passing(summary) do
    assert summary.failed == 0, "unexpected failures: #{inspect(summary.results)}"
    summary.passed
  end

  test "a struct key holding a function is callable as a method" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("invokes the stored closure", function() {
                   user = { get_emp_no: function() { return 42; }, name: "kev" };
                   assert_equal(user.get_emp_no(), 42);

                   logger = {};
                   logger.debug = function(msg) { return "dbg:" & msg; };
                   assert_equal(logger.debug("hi"), "dbg:hi");
                 });
               });
               """)
             )
  end

  test "lookup is case-insensitive, iteration preserves original key case" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("case behavior", function() {
                   s = { "AuthToken": "x" };
                   assert_equal(s.authtoken, "x");
                   assert_true(structKeyExists(s, "AUTHTOKEN"));
                   // iteration and structKeyList yield the original casing
                   keys = "";
                   for (k in s) { keys &= k; }
                   assert_equal(keys, "AuthToken");
                   assert_equal(structKeyList(s), "AuthToken");
                 });
               });
               """)
             )
  end

  test "javaCast('null', '') is null and the key is dropped (null support off)" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("null handling", function() {
                   data = { "a": javaCast("null", ""), "b": "keep" };
                   assert_false(structKeyExists(data, "a"));
                   assert_equal(data.b, "keep");
                 });
               });
               """)
             )
  end

  test "javaCast coerces simple types" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("coercions", function() {
                   assert_equal(javaCast("int", "42"), 42);
                   assert_equal(javaCast("string", 7), "7");
                   assert_true(javaCast("boolean", "yes"));
                 });
               });
               """)
             )
  end
end
