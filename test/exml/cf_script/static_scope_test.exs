defmodule ExML.CFScript.StaticScopeTest do
  @moduledoc "static { } initializer blocks, static.X reads, and static method calls."
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

  test "static methods read the static initializer scope" do
    assert 1 ==
             passing(
               run("""
               describe("statics", function() {
                 it("reads static vars", function() {
                   assert_equal(cfc.statics::greeting(), "hello");
                   assert_true(cfc.statics::under_limit(2));
                   assert_false(cfc.statics::under_limit(5));
                 });
               });
               """)
             )
  end

  test "a static method can call a sibling static method bare" do
    assert 1 ==
             passing(
               run("""
               describe("statics", function() {
                 it("sibling call", function() {
                   assert_equal(cfc.statics::shout(), "HELLO");
                 });
               });
               """)
             )
  end

  test "static array + for-in inside a static method" do
    assert 1 ==
             passing(
               run("""
               describe("statics", function() {
                 it("iterates static array", function() {
                   assert_equal(cfc.statics::word_count(), 3);
                 });
               });
               """)
             )
  end

  test "instance methods can read statics" do
    assert 1 ==
             passing(
               run("""
               describe("statics", function() {
                 it("instance reads static", function() {
                   s = new cfc.statics();
                   assert_equal(s.combined("world"), "hello world");
                 });
               });
               """)
             )
  end
end
