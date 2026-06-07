defmodule ExML.CFScript.ErrorHandlingTest do
  @moduledoc "throw, try/catch/finally, assert_throws, and named arguments."
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

  test "throw + try/catch binds the exception (type, message)" do
    assert 1 ==
             passing(
               run("""
               describe("errors", function() {
                 it("catches a thrown exception", function() {
                   caught = "";
                   ctype = "";
                   try {
                     throw(type = "MyError", message = "boom");
                   } catch (any e) {
                     caught = e.message;
                     ctype = e.type;
                   }
                   assert_equal(caught, "boom");
                   assert_equal(ctype, "MyError");
                 });
               });
               """)
             )
  end

  test "catch by specific type; finally always runs" do
    assert 1 ==
             passing(
               run("""
               describe("errors", function() {
                 it("typed catch + finally", function() {
                   log = "";
                   try {
                     throw(type = "DBError", message = "x");
                   } catch (DBError e) {
                     log &= "caught;";
                   } finally {
                     log &= "finally;";
                   }
                   assert_equal(log, "caught;finally;");
                 });
               });
               """)
             )
  end

  test "e.message.contains works in a catch body" do
    assert 1 ==
             passing(
               run("""
               describe("errors", function() {
                 it("member call on message", function() {
                   ok = false;
                   try {
                     throw(message = "Unable to parse date: foo");
                   } catch (any e) {
                     ok = e.message.contains("parse date");
                   }
                   assert_true(ok);
                 });
               });
               """)
             )
  end

  test "assert_throws: type and message matching" do
    assert 3 ==
             passing(
               run("""
               describe("errors", function() {
                 it("throws as expected", function() {
                   assert_throws(function() { throw(type = "ValidationError", message = "bad input"); },
                                 "ValidationError");
                 });
                 it("matches message substring", function() {
                   assert_throws(function() { throw(message = "value out of range"); }, "", "out of range");
                 });
                 it("plain throw", function() {
                   assert_throws(function() { throw(message = "nope"); });
                 });
               });
               """)
             )
  end

  test "assert_throws fails when nothing is thrown" do
    summary =
      run("""
      describe("errors", function() {
        it("no throw", function() {
          assert_throws(function() { x = 1; });
        });
      });
      """)

    assert summary.failed == 1
    assert [%{message: message}] = summary.results
    assert message =~ "Expected an exception but none was thrown"
  end

  test "a user function named `throw` does not shadow the built-in (no recursion)" do
    # Mirrors a CFML codebase that wraps the <cfthrow> tag in a `throw()` UDF.
    # The built-in must win so the wrapper's own throw(...) raises instead of
    # calling itself forever.
    summary =
      Runner.run_spec_source(
        """
        component {
          function throw(message, type = "Application") {
            throw(message = arguments.message, type = arguments.type);
          }
          function boom() { throw("kaboom", "MyType"); }
          function run() {
            describe("errors", function() {
              it("raises via the wrapper without recursing", function() {
                assert_throws(function() { boom(); }, "MyType", "kaboom");
              });
            });
          }
        }
        """,
        "inline.cfc",
        cfc_root: @cfc_root
      )

    assert summary.failed == 0, "unexpected failures: #{inspect(summary.results)}"
    assert summary.passed == 1
  end

  test "named arguments bind by name to a method (any order)" do
    assert 1 ==
             passing(
               run("""
               describe("named args", function() {
                 it("binds by name", function() {
                   common = new cfc.common();
                   // common.capitalize(str) — pass by name
                   assert_equal(common.capitalize(str = "hello"), "Hello");
                 });
               });
               """)
             )
  end
end
