defmodule ExML.CFScript.NativeObjectTest do
  @moduledoc "Host objects (request.logger backed by Elixir Logger)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExML.CFScript.{NativeObject, Runner}

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body) do
    Runner.run_spec_source(
      "component { function run() { #{body} } }",
      "inline.cfc",
      cfc_root: @cfc_root,
      scopes: %{"request" => %{"logger" => NativeObject.logger()}}
    )
  end

  test "request.logger.info logs via Elixir Logger" do
    log =
      capture_log(fn ->
        summary =
          run("""
          describe("logging", function() {
            it("logs", function() {
              request.logger.info("hello from cfml");
              request.logger.debug("a debug line");
            });
          });
          """)

        assert summary.failed == 0
      end)

    assert log =~ "hello from cfml"
  end

  test "unknown methods are chainable no-ops (builder pattern)" do
    log =
      capture_log(fn ->
        summary =
          run("""
          describe("logging", function() {
            it("chains build", function() {
              request.logger.build("ctx").info("after build");
            });
          });
          """)

        assert summary.failed == 0
      end)

    assert log =~ "after build"
  end
end
