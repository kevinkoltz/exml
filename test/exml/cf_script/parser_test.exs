defmodule ExML.CFScript.ParserTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.{AST, Parser}

  describe "expressions" do
    test "operator precedence: & binds tighter than ==" do
      assert Parser.parse_expression("len(str) == 1") ==
               {:binop, "==", {:call, {:var, "len"}, [{:var, "str"}]}, {:lit, 1}}
    end

    test "concat with calls and subtraction" do
      assert Parser.parse_expression("ucase(left(str, 1)) & right(str, len(str)-1)") ==
               {:binop, "&",
                {:call, {:var, "ucase"}, [{:call, {:var, "left"}, [{:var, "str"}, {:lit, 1}]}]},
                {:call, {:var, "right"},
                 [
                   {:var, "str"},
                   {:binop, "-", {:call, {:var, "len"}, [{:var, "str"}]}, {:lit, 1}}
                 ]}}
    end

    test "static call on a cfc path" do
      assert Parser.parse_expression("cfc.value::is_blank(str)") ==
               {:call, {:static_member, {:member, {:var, "cfc"}, "value"}, "is_blank"},
                [{:var, "str"}]}
    end

    test "member call chain" do
      assert Parser.parse_expression(~s|(arguments.value & "").trim().len()|) ==
               {:call,
                {:member,
                 {:call,
                  {:member, {:binop, "&", {:member, {:var, "arguments"}, "value"}, {:lit, ""}},
                   "trim"}, []}, "len"}, []}
    end

    test "not / or precedence" do
      assert Parser.parse_expression("not a or b") ==
               {:binop, "or", {:unop, "not", {:var, "a"}}, {:var, "b"}}
    end

    test "new component" do
      assert Parser.parse_expression("new cfc.common()") == {:new, "cfc.common", []}
    end
  end

  describe "component" do
    test "parses the capitalize function" do
      src = ~s"""
      component {
        function capitalize(str) localmode=true {
          if (cfc.value::is_blank(str)) return "";
          if (len(str) == 1) return ucase(str);
          return ucase(left(str, 1)) & right(str, len(str)-1);
        }
      }
      """

      assert %AST.Component{functions: [func]} = Parser.parse_component(src)
      assert %AST.Function{name: "capitalize", params: [%AST.Param{name: "str"}]} = func
      assert length(func.body) == 3
      assert [{:if, _, _, _}, {:if, _, _, _}, {:return, _}] = func.body
    end

    test "parses static + return type + extends attribute" do
      src = ~s"""
      component extends="test.test_framework" {
        static boolean function is_blank(value) localmode=true {
          return true;
        }
      }
      """

      assert %AST.Component{extends: "test.test_framework", functions: [func]} =
               Parser.parse_component(src)

      assert %AST.Function{name: "is_blank", static: true, return_type: "boolean"} = func
    end

    test "parses anonymous function arguments (describe/it)" do
      src = ~s"""
      component {
        function run() {
          describe("group", function() {
            it("works", function() {
              assert_equal(common.capitalize("hello"), "Hello");
            });
          });
        }
      }
      """

      assert %AST.Component{functions: [%AST.Function{name: "run", body: body}]} =
               Parser.parse_component(src)

      assert [{:expr, {:call, {:var, "describe"}, [{:lit, "group"}, {:fun, [], _}]}}] = body
    end
  end
end
