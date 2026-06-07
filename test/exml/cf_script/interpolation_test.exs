defmodule ExML.CFScript.InterpolationTest do
  @moduledoc "String interpolation (#expr#) and the reReplace/replace BIFs."
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R
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

  test "string interpolation" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("interpolates", function() {
                   name = "world";
                   n = 3;
                   assert_equal("hello #name#!", "hello world!");
                   assert_equal("n=#n#", "n=3");
                   // ## is an escaped literal '#': "a ## b" is 5 chars (a,space,#,space,b)
                   assert_equal(len("a ## b"), 5);
                   assert_equal("#ucase(name)#", "WORLD");
                 });
               });
               """)
             )
  end

  describe "reReplace / replace BIFs" do
    test "reReplace with backreferences, scope all" do
      assert R.call("reReplace", ["AuthToken", "([a-z])([A-Z])", "\\1_\\2", "all"]) ==
               "Auth_Token"
    end

    test "reReplace default scope replaces first only" do
      assert R.call("reReplace", ["a1b2", "[0-9]", "#", "one"]) == "a#b2"
    end

    test "reReplaceNoCase" do
      assert R.call("reReplaceNoCase", ["Hello", "h", "J", "all"]) == "Jello"
    end

    test "literal replace" do
      assert R.call("replace", ["a.b.c", ".", "-", "all"]) == "a-b-c"
      assert R.call("replace", ["a.b.c", ".", "-"]) == "a-b.c"
    end

    test "reMatch" do
      assert R.call("reMatch", ["[0-9]+", "a12b345"]) == ["12", "345"]
    end
  end
end
