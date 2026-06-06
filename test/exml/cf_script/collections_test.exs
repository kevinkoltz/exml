defmodule ExML.CFScript.CollectionsTest do
  @moduledoc """
  End-to-end interpreter tests for array/struct literals and the higher-order
  member functions (which need the interpreter to invoke closures).
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body) do
    source = """
    component {
      function run() {
        #{body}
      }
    }
    """

    Runner.run_spec_source(source, "inline.cfc", cfc_root: @cfc_root)
  end

  test "array literal + map/filter/reduce closures" do
    summary =
      run("""
      describe("collections", function() {
        it("maps", function() {
          nums = [1, 2, 3];
          doubled = nums.map(function(n) { return n * 2; });
          assert_equal(arrayToList(doubled), "2,4,6");
        });

        it("filters", function() {
          nums = [1, 2, 3, 4];
          evens = nums.filter(function(n) { return n % 2 == 0; });
          assert_equal(arrayToList(evens), "2,4");
        });

        it("reduces", function() {
          total = [1, 2, 3, 4].reduce(function(acc, n) { return acc + n; }, 0);
          assert_equal(total, 10);
        });

        it("some / every", function() {
          assert_true([1, 2, 3].some(function(n) { return n == 2; }));
          assert_false([1, 2, 3].every(function(n) { return n == 2; }));
        });
      });
      """)

    assert summary.failed == 0
    assert summary.passed == 4
  end

  test "struct literal + member functions" do
    summary =
      run("""
      describe("structs", function() {
        it("reads keys", function() {
          person = {name: "Ada", role: "eng"};
          assert_equal(person.name, "Ada");
          assert_true(person.keyExists("role"));
          assert_false(person.keyExists("missing"));
        });

        it("counts", function() {
          assert_equal(structCount({a: 1, b: 2}), 2);
        });
      });
      """)

    assert summary.failed == 0
    assert summary.passed == 2
  end

  test "array member helpers (len, append, contains, first/last)" do
    summary =
      run("""
      describe("array members", function() {
        it("len and append", function() {
          xs = [1, 2];
          assert_equal(xs.len(), 2);
          assert_equal(arrayToList(xs.append(3)), "1,2,3");
        });

        it("contains / first / last", function() {
          xs = ["a", "b", "c"];
          assert_equal(xs.first(), "a");
          assert_equal(xs.last(), "c");
          assert_true(arrayContains(xs, "b") == 2);
        });
      });
      """)

    assert summary.failed == 0
    assert summary.passed == 2
  end
end
