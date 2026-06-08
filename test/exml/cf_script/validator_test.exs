defmodule ExML.CFScript.ValidatorTest do
  @moduledoc """
  Build-time validation: `.cfc`/`.cfm` source yields diagnostics (syntax errors
  and unsupported-construct usage) so a host can fail the build instead of
  letting the code crash lazily at runtime.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Validator

  defp errors(diags), do: Enum.filter(diags, &(&1.severity == :error))

  describe "validate_cfm/3" do
    test "a clean template has no diagnostics" do
      assert Validator.validate_cfm("<p>Hi <cfoutput>#name#</cfoutput></p>", "ok.cfm") == []
    end

    test "an unsupported tag is an error at its line" do
      src = "<p>ok</p>\n<cffile action=\"read\" file=\"x\" variable=\"y\">"
      assert [diag] = Validator.validate_cfm(src, "f.cfm")
      assert diag.severity == :error
      assert diag.kind == :unsupported
      assert diag.line == 2
      assert diag.message =~ "cffile"
    end

    test "an inline @exml-allow directive downgrades the construct to a warning" do
      src = "<!--- @exml-allow cffile --->\n<cffile action=\"read\" file=\"x\">"
      assert [diag] = Validator.validate_cfm(src, "f.cfm")
      assert diag.severity == :warning
      assert diag.kind == :unsupported
    end

    test "the :allow option downgrades the construct to a warning" do
      src = "<cffile action=\"read\" file=\"x\">"
      assert [diag] = Validator.validate_cfm(src, "f.cfm", allow: ["cffile"])
      assert diag.severity == :warning
    end

    test "a broken statement is a syntax error at its line" do
      src = "<p>ok</p>\n<cfset x = >"
      assert [diag] = Validator.validate_cfm(src, "broke.cfm")
      assert diag.severity == :error
      assert diag.kind == :syntax
      assert diag.line == 2
    end
  end

  describe "validate_cfc/3" do
    test "a clean component has no diagnostics" do
      src = "component { function ok() { return 1; } }"
      assert Validator.validate_cfc(src, "ok.cfc") == []
    end

    test "an unsupported tag inside a function is an error at its line" do
      src = """
      component {
        function f() {
          <cffile action="read" file="x">
        }
      }
      """

      assert [diag] = Validator.validate_cfc(src, "c.cfc")
      assert diag.severity == :error
      assert diag.kind == :unsupported
      assert diag.line == 3
      assert diag.message =~ "cffile"
    end

    test "only the offending function is flagged; siblings validate clean" do
      src = """
      component {
        function clean() { return ucase("hi"); }
        function dirty() {
          <cfftp action="open" server="s">
        }
      }
      """

      assert [diag] = Validator.validate_cfc(src, "c.cfc")
      assert diag.kind == :unsupported
      assert diag.message =~ "cfftp"
      assert errors([diag]) == [diag]
    end

    test "the :allow option downgrades an unsupported construct" do
      src = """
      component {
        function f() { <cfftp action="open" server="s"> }
      }
      """

      assert [diag] = Validator.validate_cfc(src, "c.cfc", allow: ["cfftp"])
      assert diag.severity == :warning
    end
  end
end
