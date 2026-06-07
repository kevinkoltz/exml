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

  test "a cffunction with an unconvertible tag body (cfloop) is dropped" do
    summary =
      run("""
      describe("g", function() {
        it("has no tag_loop_fn", function() {
          common.tag_loop_fn();
        });
      });
      """)

    assert summary.failed == 1
    assert [%{status: :fail, message: message}] = summary.results
    assert message =~ "tag_loop_fn"
  end
end
