defmodule ExML.CFScript.DatesTest do
  @moduledoc "Dates through the interpreter: comparison, arithmetic, interpolation."
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

  test "dates compare numerically and format via interpolation" do
    assert 1 ==
             passing(
               run("""
               describe("dates", function() {
                 it("compare + format", function() {
                   start = createDate(2023, 1, 1);
                   finish = createDateTime(2023, 6, 15, 9, 30, 0);
                   assert_true(start < finish);
                   assert_false(finish < start);
                   assert_equal(dateDiff("d", start, finish), 165);
                   assert_equal("on #dateFormat(finish, "yyyy-mm-dd")# at #timeFormat(finish, "HH:mm")#",
                                "on 2023-06-15 at 09:30");
                   assert_true(isDate(finish));
                   assert_true(isSimpleValue(finish));
                 });
               });
               """)
             )
  end
end
