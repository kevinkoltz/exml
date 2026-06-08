defmodule ExML.CFScript.RendererTest do
  @moduledoc """
  Rendering `.cfm` templates: literal text, `<cfoutput>` interpolation,
  `<cfscript>`, control-flow tags, `<cfinclude>`, `<cfmodule>` (custom-tag
  scoping), and `<cfquery>` row loops — output accumulates in the buffer.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript

  @cfm_root Path.join(__DIR__, "../../fixtures/cfm") |> Path.expand()

  defp render(source, opts \\ []) do
    source |> CFScript.render_cfm(opts) |> IO.iodata_to_binary()
  end

  describe "text, output, and interpolation" do
    test "literal HTML passes through unchanged" do
      assert render("<p>Hello world</p>") == "<p>Hello world</p>"
    end

    test "#expr# interpolates only inside <cfoutput>" do
      src = "<p>raw #name#</p><cfoutput>out #name#</cfoutput>"
      assert render(src, assigns: %{name: "Kev"}) == "<p>raw #name#</p>out Kev"
    end

    test "## stays literal outside cfoutput; a quote is preserved" do
      assert render(~s|<a href="##top" title="a""b">x</a>|) ==
               ~s|<a href="##top" title="a""b">x</a>|
    end

    test "<cfscript> blocks execute and writeOutput emits" do
      assert render("<cfscript>writeOutput(ucase(\"hi\"));</cfscript>") == "HI"
    end

    test "writeOutput inside cfoutput interpolation chain" do
      assert render("<cfoutput>#1 + 2#</cfoutput>") == "3"
    end
  end

  describe "control flow tags keep their text bodies" do
    test "<cfif>/<cfelse>" do
      src = "<cfif n gt 1>many<cfelse>one</cfif>"
      assert render(src, assigns: %{n: 5}) == "many"
      assert render(src, assigns: %{n: 1}) == "one"
    end

    test "<cfloop array=> emits each iteration's text" do
      src = ~s|<cfloop array="#items#" item="i"><cfoutput>[#i#]</cfoutput></cfloop>|
      assert render(src, assigns: %{items: ["a", "b", "c"]}) == "[a][b][c]"
    end

    test "<cfswitch>/<cfcase>" do
      src =
        ~s|<cfswitch expression="#k#"><cfcase value="a">AY</cfcase><cfdefaultcase>?</cfdefaultcase></cfswitch>|

      assert render(src, assigns: %{k: "a"}) == "AY"
      assert render(src, assigns: %{k: "z"}) == "?"
    end

    test "<cfparam> supplies a default" do
      assert render(~s|<cfparam name="msg" default="hi"><cfoutput>#msg#</cfoutput>|) == "hi"
    end
  end

  describe "<cfinclude>" do
    test "a relative include shares the page scopes" do
      src = ~s|A<cfinclude template="_partial.cfm">B|

      out =
        render(src, assigns: %{name: "Kev"}, template_dir: @cfm_root, template_root: @cfm_root)

      assert out == "A<span>partial:Kev</span>B"
    end

    test "an absolute include resolves from template_root" do
      src = ~s|<cfinclude template="/shared/footer.cfm">|

      assert render(src, template_dir: @cfm_root, template_root: @cfm_root) ==
               "<footer>shared footer</footer>"
    end

    test "a missing include raises loudly" do
      assert_raise File.Error, fn ->
        render(~s|<cfinclude template="nope.cfm">|, template_dir: @cfm_root)
      end
    end
  end

  describe "<cfmodule> custom tags" do
    test "reads attributes, writes caller, and splices output" do
      src = ~s|<cfmodule template="greet.cfm" who="World">[<cfoutput>#greeted#</cfoutput>]|
      out = render(src, template_dir: @cfm_root, template_root: @cfm_root)
      assert out == "Hi World[true]"
    end

    test "the tag cannot see the caller's variables unscoped (isolation)" do
      src = ~s|<cfmodule template="leaky.cfm">|

      assert_raise ExML.CFScript.CFException, ~r/secret/, fn ->
        render(src, assigns: %{secret: "x"}, template_dir: @cfm_root, template_root: @cfm_root)
      end
    end
  end

  describe "<cfquery> + query loops" do
    test "<cfoutput query=> iterates the result rows" do
      executor = fn _sql, _params ->
        %{columns: ["name"], rows: [["a"], ["b"], ["c"]]}
      end

      src =
        ~s|<cfquery name="rows">SELECT name FROM t</cfquery><cfoutput query="rows">#rows.name#,</cfoutput>|

      assert render(src, query_executor: executor) == "a,b,c,"
    end

    test "<cfloop query=> iterates the result rows" do
      executor = fn _sql, _params -> %{columns: ["id"], rows: [[1], [2]]} end

      src =
        ~s|<cfquery name="r">SELECT id FROM t</cfquery><cfloop query="r"><cfoutput>#r.id#;</cfoutput></cfloop>|

      assert render(src, query_executor: executor) == "1;2;"
    end
  end

  describe "unsupported constructs crash loudly" do
    test "an unhandled tag raises exml.unsupported" do
      assert_raise ExML.CFScript.CFException, ~r/cffile/, fn ->
        render(~s|<cffile action="read" file="x">|)
      end
    end
  end

  describe "ahead-of-time compile (compile_cfm + render_cfm_ast)" do
    test "parse-then-escape-then-render matches direct rendering (the engine path)" do
      src = "<p>Hi <cfoutput>#name#</cfoutput></p>"
      # Mirror a Phoenix.Template engine: parse at compile time, embed via
      # Macro.escape, render the recovered AST at runtime.
      ast = CFScript.compile_cfm(src, "x.cfm")
      {recovered, _} = Code.eval_quoted(Macro.escape(ast))
      out = CFScript.render_cfm_ast(recovered, assigns: %{name: "Kev"}) |> IO.iodata_to_binary()
      assert out == "<p>Hi Kev</p>"
    end

    test "a recoverable syntax error compiles to an unsupported marker (the Mix compiler gates it)" do
      # compile_cfm uses the parser's statement-level recovery, so a bad statement
      # does not raise here — it becomes an {:unsupported, _} node. The :cfml Mix
      # compiler (ExML.CFScript.validate_cfm) is what turns that into a build
      # error; rendering it would raise at runtime.
      ast = CFScript.compile_cfm("<cfset x = >", "bad.cfm")
      assert [diag] = CFScript.validate_cfm("<cfset x = >", "bad.cfm")
      assert diag.severity == :error and diag.kind == :syntax
      assert is_list(ast)
    end
  end

  describe "real self-contained Signal pages" do
    test "403-style pure HTML page" do
      html = ~s|<div><p>Sorry, you do not have permission.</p></div>|
      assert render(html) == html
    end

    test "simple_jt-style cfparam + cfoutput" do
      src = ~s|<cfparam name="url.msg" default="hello"><div><cfoutput>#url.msg#</cfoutput></div>|
      assert render(src, url: %{msg: "world"}) == "<div>world</div>"
    end

    test "echo_url-style cfscript writeOutput of a cgi value" do
      src = ~s|<cfscript>writeOutput(cgi.query_string);</cfscript>|
      assert render(src, cgi: %{query_string: "a=1&b=2"}) == "a=1&b=2"
    end
  end
end
