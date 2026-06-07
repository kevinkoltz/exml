defmodule ExML.CFScript.TagConverterTest do
  @moduledoc "CFML tag -> cfscript conversion: attribute parsing and per-tag output."
  use ExUnit.Case, async: true

  alias ExML.CFScript.TagConverter

  describe "parse_attrs / attrs_map (quoting nuances)" do
    test "double-quoted, single-quoted, unquoted, and bare attributes" do
      attrs = TagConverter.attrs_map(~s|name="some_name" alt='x' localmode=true output|)
      assert attrs["name"] == "some_name"
      assert attrs["alt"] == "x"
      assert attrs["localmode"] == "true"
      # a bare boolean attribute has no value
      assert Map.fetch(attrs, "output") == {:ok, nil}
    end

    test "keys are case-insensitive; interpolation and doubled quotes survive" do
      attrs = TagConverter.attrs_map(~s|VALUE="#arguments.x#" Msg="say ""hi"""|)
      assert attrs["value"] == "#arguments.x#"
      assert attrs["msg"] == ~s(say "hi")
    end

    test "order is preserved" do
      assert [{"a", "1"}, {"b", "2"}] = TagConverter.parse_attrs(~s|a="1" b="2"|)
    end
  end

  describe "convert_body" do
    test "cfset / cfreturn" do
      assert TagConverter.convert_body(~s|<cfset x = 1><cfreturn x>|) =~ "x = 1;"
      assert TagConverter.convert_body(~s|<cfreturn x>|) =~ "return x;"
    end

    test "cfthrow becomes throw() with named args" do
      out = TagConverter.convert_body(~s|<cfthrow message="boom #x#" type="validation">|)
      assert out =~ ~s|throw(message = "boom #x#", type = "validation");|
    end

    test "cfquery + cfqueryparam becomes queryExecute with params" do
      out =
        TagConverter.convert_body(
          ~s|<cfquery name="q">SELECT 1 WHERE id = <cfqueryparam value="#id#" cfsqltype="cf_sql_integer"></cfquery>|
        )

      assert out =~ "q = queryExecute("
      assert out =~ ":qp1"
      assert out =~ ~s|qp1: {value: id, sqltype: "integer"}|
    end

    test "cfinvoke with component path and arguments" do
      out =
        TagConverter.convert_body("""
        <cfinvoke component="cfc.svc" method="run" returnvariable="r">
          <cfinvokeargument name="a" value="#x#">
          <cfinvokeargument name="b" value="lit">
        </cfinvoke>
        """)

      assert out =~ ~s|r = new cfc.svc().run(a = x, b = "lit");|
    end

    test "cfinvoke on an instance expression" do
      out = TagConverter.convert_body(~s|<cfinvoke component="#obj#" method="go" />|)
      assert out =~ "obj.go();"
    end

    test "cftry/cfcatch becomes try/catch (cfcatch)" do
      out =
        TagConverter.convert_body(
          ~s|<cftry><cfset risky()><cfcatch type="any"><cfset handled = true></cfcatch></cftry>|
        )

      assert out =~ "try {"
      assert out =~ "} catch (any cfcatch) {"
    end

    test "cfparam assigns the default only when absent (null-safe)" do
      assert TagConverter.convert_body(~s|<cfparam name="x" default="d">|) =~ ~s|x = x ?: "d";|
    end

    test "cftransaction and cfoutput are unwrapped; cfmail/cfdump dropped" do
      assert TagConverter.convert_body(~s|<cftransaction><cfset a = 1></cftransaction>|) =~
               "a = 1;"

      assert TagConverter.convert_body(~s|<cfoutput><cfset b = 2></cfoutput>|) =~ "b = 2;"
      refute TagConverter.convert_body(~s|<cfmail to="x">hi #n#</cfmail>|) =~ "hi"
      refute TagConverter.convert_body(~s|<cfdump var="#x#">|) =~ "cfdump"
    end

    test "cfsavecontent becomes a string assignment, keeping interpolation" do
      out =
        TagConverter.convert_body(~s|<cfsavecontent variable="h"><p>#name#</p></cfsavecontent>|)

      assert out =~ ~s|h = "<p>#name#</p>";|
    end

    test "cfabort / cfbreak / cfrethrow" do
      assert TagConverter.convert_body("<cfbreak>") =~ "break;"
      assert TagConverter.convert_body("<cfabort>") =~ "throw(message = \"cfabort\");"
      assert TagConverter.convert_body("<cfrethrow>") =~ "throw(message = cfcatch.message"
    end
  end

  describe "convert_cffunctions (attribute forms)" do
    test "unquoted localmode=true carries the modifier" do
      out =
        TagConverter.convert_cffunctions(
          ~s|<cffunction name=foo localmode=true><cfreturn 1></cffunction>|
        )

      assert out =~ "function foo() localmode=\"true\" {"
    end

    test "quoted localmode=\"modern\" carries the modifier" do
      out =
        TagConverter.convert_cffunctions(
          ~s|<cffunction name="foo" localmode="modern"><cfreturn 1></cffunction>|
        )

      assert out =~ ~s|function foo() localmode="modern" {|
    end

    test "cfargument types/required/default become the parameter list" do
      out =
        TagConverter.convert_cffunctions("""
        <cffunction name="f">
          <cfargument name="a" type="numeric" required="true">
          <cfargument name="b" default="x">
          <cfreturn a>
        </cffunction>
        """)

      assert out =~ ~s|function f(required numeric a, b = "x")|
    end
  end
end
