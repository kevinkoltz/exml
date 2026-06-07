defmodule ExML.CFScript.LoaderTest do
  @moduledoc "Loading tag CFCs: `<cffunction>` is rewritten to cfscript `function`."
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body) do
    Runner.run_spec_source(
      "component { function run() { common = new cfc.common(); #{body} } }",
      "inline.cfc",
      cfc_root: @cfc_root
    )
  end

  defp passing(summary) do
    assert summary.failed == 0, "unexpected failures: #{inspect(summary.results)}"
    summary.passed
  end

  test "converts a tag-bodied cffunction with cfif/cfset/cfreturn" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("describes the sign", function() {
                   assert_equal(common.describe_sign(5), "positive");
                   assert_equal(common.describe_sign(-2), "negative");
                   assert_equal(common.describe_sign(0), "zero");
                 });
               });
               """)
             )
  end

  test "converts a tag-bodied cffunction with cfswitch/cfcase/cfdefaultcase" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("names the day", function() {
                   assert_equal(common.day_name(1), "Mon");
                   assert_equal(common.day_name(2), "Tue");
                   assert_equal(common.day_name(7), "Other");
                 });
               });
               """)
             )
  end

  test "cfscript-bodied siblings still load alongside converted tag functions" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("capitalizes", function() {
                   assert_equal(common.capitalize("hello"), "Hello");
                 });
               });
               """)
             )
  end

  test "converts a tag-bodied cffunction with a cfloop (from/to)" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("loops", function() {
                   assert_equal(common.tag_loop_fn(), "123");
                 });
               });
               """)
             )
  end

  test "converts a tag-bodied cffunction with a cfloop (list, scoped index)" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("loops a list", function() {
                   assert_equal(common.tag_list_loop_fn("a,b,c"), "ABC");
                 });
               });
               """)
             )
  end

  test "converts cfquery + cfqueryparam + cftry/cfcatch (catch path, no executor)" do
    # No query executor is configured, so queryExecute raises; the converted
    # cftry/cfcatch must catch it and return the catch-path value.
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("falls into the catch", function() {
                   result = common.tag_query_fn(7);
                   assert_true(left(result, 7) == "error: ");
                 });
               });
               """)
             )
  end

  test "a cffunction with an unconvertible tag body (cffile) is dropped" do
    summary =
      run("""
      describe("g", function() {
        it("has no tag_file_fn", function() {
          common.tag_file_fn();
        });
      });
      """)

    assert summary.failed == 1
    # A missing function is an unexpected runtime fault, not an assertion failure.
    assert [%{status: :error, message: message}] = summary.results
    assert message =~ "tag_file_fn"
  end

  test "top-level `name = function(){}` loads as a callable method" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 fx = new cfc.fnexpr();
                 it("method expressions are callable, incl. sibling calls", function() {
                   assert_equal(fx.double(5), 10);
                   assert_equal(fx.triple(5), 15);
                   assert_equal(fx.sextuple(5), 25);
                 });
               });
               """)
             )
  end
end
