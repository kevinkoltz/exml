defmodule ExML.CFScript.ScopesTest do
  @moduledoc """
  Predefined CFML scopes (request/application/cgi/...) seeded by the host, since
  the interpreter doesn't run the Application.cfc request lifecycle.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body, opts) do
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

  @seed %{
    "request" => %{"db_name" => "appdb", "dsn" => "maindb"},
    "application" => %{"hostname" => "web01"},
    "cgi" => %{"script_name" => "/test.cfm"}
  }

  test "reads seeded request/application/cgi values" do
    assert 1 ==
             passing(
               run(
                 """
                 describe("scopes", function() {
                   it("reads seeded values", function() {
                     assert_equal(request.db_name, "appdb");
                     assert_equal("#request.db_name#.dbo.employees", "appdb.dbo.employees");
                     assert_equal(application.hostname, "web01");
                     assert_equal(cgi.script_name, "/test.cfm");
                     assert_true(structKeyExists(request, "dsn"));
                   });
                 });
                 """,
                 scopes: @seed
               )
             )
  end

  test "scopes are writable and shared across method calls within a run" do
    assert 1 ==
             passing(
               run(
                 """
                 describe("scopes", function() {
                   it("writes request", function() {
                     request.flash = "saved";
                     assert_equal(request.flash, "saved");
                   });
                 });
                 """,
                 scopes: @seed
               )
             )
  end

  test "missing scope key raises (null support off)" do
    summary =
      run(
        """
        describe("scopes", function() {
          it("missing key", function() {
            x = request.nope;
          });
        });
        """,
        scopes: @seed
      )

    assert summary.failed == 1
    assert [%{message: message}] = summary.results
    assert message =~ "doesn't exist"
  end

  test "unqualified reads do NOT fall through to predefined scopes" do
    summary =
      run(
        """
        describe("scopes", function() {
          it("no scope hunt", function() {
            x = db_name;
          });
        });
        """,
        scopes: @seed
      )

    assert summary.failed == 1
    assert [%{message: message}] = summary.results
    assert message =~ "undefined"
  end
end
