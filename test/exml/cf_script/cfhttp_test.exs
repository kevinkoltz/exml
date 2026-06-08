defmodule ExML.CFScript.CfhttpTest do
  @moduledoc """
  The cfscript script-tag-block form `cfhttp(attrs) { cfhttpparam... }`: the
  request is built from the tag's attributes plus its `cfhttpparam` children and
  run through the pluggable `:http_executor`, which binds a response struct.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body, opts \\ []) do
    Runner.run_spec_source(
      "component { function run() { #{body} } }",
      "inline.cfc",
      Keyword.merge([cfc_root: @cfc_root, http_executor: :stub], opts)
    )
  end

  defp passing(summary) do
    assert summary.failed == 0, "unexpected failures: #{inspect(summary.results)}"
    summary.passed
  end

  test "cfhttp binds the stubbed response struct to `result`" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("runs an http call", function() {
                   cfhttp(url="http://example.com/echo", method="GET", result="resp") {
                     cfhttpparam(name="token", value="abc", type="url");
                   }
                   assert_equal(resp.statusCode, "200 OK");
                   assert_equal(resp.status_code, 200);
                 });
               });
               """)
             )
  end

  test "request captures method, url, and cfhttpparam children" do
    captured =
      run(
        """
        describe("g", function() {
          it("captures the request", function() {
            cfhttp(url="http://example.com/api", method="post", result="resp") {
              cfhttpparam(name="a", value="1", type="formfield");
              cfhttpparam(name="b", value="2", type="url");
            }
            request.captured = resp.request;
          });
        });
        """,
        scopes: %{"request" => %{}}
      )

    assert captured.failed == 0
  end

  test "default result variable is `cfhttp` when no result attr is given" do
    assert 1 ==
             passing(
               run("""
               describe("g", function() {
                 it("defaults to cfhttp", function() {
                   cfhttp(url="http://example.com", method="GET") {}
                   assert_equal(cfhttp.statusCode, "200 OK");
                 });
               });
               """)
             )
  end

  test "cfhttp without a configured executor raises a clear error" do
    summary =
      run(
        """
        describe("g", function() {
          it("needs an executor", function() {
            cfhttp(url="http://example.com", method="GET") {}
          });
        });
        """,
        http_executor: nil
      )

    assert summary.failed == 1
    [result] = Enum.filter(summary.results, &(&1.status != :pass))
    assert result.detail =~ "http executor" or result.message =~ "http executor"
  end
end
