defmodule ExML.CFScript.QueryTest do
  @moduledoc """
  Query object semantics (in-memory builders) and queryExecute against a
  pluggable executor shaped like `Ecto.Repo.query/2`.
  """
  use ExUnit.Case, async: true

  alias ExML.CFScript.Runner

  @cfc_root Path.join(__DIR__, "../../fixtures/cfc") |> Path.expand()

  defp run(body, opts \\ []) do
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

  test "queryNew + queryAddRow + recordCount + column[row] (the scrub_query API)" do
    assert 1 ==
             passing(
               run("""
               describe("q", function() {
                 it("builds and reads", function() {
                   q = queryNew("username,password_hash", "varchar,varchar");
                   queryAddRow(q, { username: "kevin", password_hash: "abc" });
                   queryAddRow(q, { username: "jane", password_hash: "xyz" });
                   assert_equal(q.recordCount, 2);
                   assert_equal(q.columnList, "username,password_hash");
                   assert_equal(q.username[1], "kevin");
                   assert_equal(q.password_hash[2], "xyz");
                 });
               });
               """)
             )
  end

  test "querySetCell mutates in place (reference type), default row is the last" do
    assert 1 ==
             passing(
               run("""
               describe("q", function() {
                 it("sets cells", function() {
                   q = queryNew("a", "varchar");
                   queryAddRow(q, { a: "one" });
                   queryAddRow(q, { a: "two" });
                   querySetCell(q, "a", "X", 1);
                   querySetCell(q, "a", "LAST");
                   assert_equal(q.a[1], "X");
                   assert_equal(q.a[2], "LAST");
                 });
               });
               """)
             )
  end

  test "isQuery, valueList and duplicate(query) deep-copies" do
    assert 1 ==
             passing(
               run("""
               describe("q", function() {
                 it("predicates and copy", function() {
                   q = queryNew("a", "varchar");
                   queryAddRow(q, { a: "1" });
                   queryAddRow(q, { a: "2" });
                   assert_true(isQuery(q));
                   assert_false(isQuery("nope"));
                   assert_equal(valueList(q.a), "1,2");
                   copy = duplicate(q);
                   queryAddRow(copy, { a: "3" });
                   assert_equal(q.recordCount, 2);
                   assert_equal(copy.recordCount, 3);
                 });
               });
               """)
             )
  end

  test "query_executor: :stub returns an empty result without a database" do
    assert 1 ==
             passing(
               run(
                 """
                 describe("q", function() {
                   it("stubbed", function() {
                     q = queryExecute("SELECT * FROM whatever");
                     assert_equal(q.recordCount, 0);
                   });
                 });
                 """,
                 query_executor: :stub
               )
             )
  end

  test "queryExecute returns a query from the executor (repo-shaped result)" do
    executor = fn _sql, _params ->
      %{columns: ["id", "name"], rows: [[1, "kevin"], [2, "jane"]]}
    end

    assert 1 ==
             passing(
               run(
                 """
                 describe("q", function() {
                   it("runs sql", function() {
                     q = queryExecute("SELECT id, name FROM users");
                     assert_equal(q.recordCount, 2);
                     assert_equal(q.name[2], "jane");
                   });
                 });
                 """,
                 query_executor: executor
               )
             )
  end

  test "queryExecute with a TOP 1 single-row result" do
    # The common `SELECT TOP 1 ... WHERE x = :id` shape with a named param.
    # The executor returns plain Elixir values (a host adapter normalizes
    # database Decimal/date types before handing rows to the interpreter).
    executor = fn _sql, _params ->
      %{columns: ["total"], rows: [["12.50"]]}
    end

    assert 1 ==
             passing(
               run(
                 """
                 describe("q", function() {
                   it("top 1", function() {
                     row = queryExecute(
                       "SELECT TOP 1 total FROM accounts WHERE id = :id",
                       { id: { value: "ABC", sqltype: "char" } }
                     );
                     assert_equal(row.recordCount, 1);
                     assert_equal(row.total[1], "12.50");
                   });
                 });
                 """,
                 query_executor: executor
               )
             )
  end

  test "queryExecute returnType=array yields an array of row structs" do
    executor = fn _sql, _params -> %{columns: ["id"], rows: [[1], [2]]} end

    assert 1 ==
             passing(
               run(
                 """
                 describe("q", function() {
                   it("returns array", function() {
                     rows = queryExecute("SELECT id FROM t", {}, { returnType: "array" });
                     assert_true(isArray(rows));
                     assert_equal(arrayLen(rows), 2);
                     assert_equal(rows[1].id, 1);
                   });
                 });
                 """,
                 query_executor: executor
               )
             )
  end

  test "executor receives plain deep-derefed params (no heap refs)" do
    test_pid = self()

    executor = fn sql, params ->
      send(test_pid, {:executed, sql, params})
      %{columns: ["ok"], rows: [[1]]}
    end

    run(
      """
      describe("q", function() {
        it("passes params", function() {
          queryExecute("DELETE FROM t WHERE id = :id", { id: { value: "ABC", sqltype: "char" } });
        });
      });
      """,
      query_executor: executor
    )

    assert_received {:executed, "DELETE FROM t WHERE id = :id", params}
    # Named param + nested {value, sqltype} descriptor arrive as plain maps.
    assert params == %{"id" => %{"value" => "ABC", "sqltype" => "char"}}
  end

  test "a 3-arity executor receives the query options (e.g. datasource)" do
    test_pid = self()

    executor = fn _sql, _params, options ->
      send(test_pid, {:executed, options})
      %{columns: ["ok"], rows: [[1]]}
    end

    run(
      """
      describe("q", function() {
        it("threads datasource", function() {
          queryExecute("SELECT 1", {}, { datasource: "mbx" });
        });
      });
      """,
      query_executor: executor
    )

    assert_received {:executed, %{"datasource" => "mbx"}}
  end

  test "<cfquery datasource=> threads the datasource to the executor" do
    test_pid = self()

    executor = fn _sql, _params, options ->
      send(test_pid, {:executed, options})
      %{columns: ["ok"], rows: [[1]]}
    end

    # A tag-form query (converted to queryExecute with an options map).
    ExML.CFScript.Runner.run_spec_source(
      ~s|component { function run() { <cfquery name="q" datasource="mbx">SELECT 1</cfquery> } }|,
      "inline.cfc",
      cfc_root: @cfc_root,
      query_executor: executor
    )

    assert_received {:executed, %{"datasource" => "mbx"}}
  end

  test "queryExecute without an executor raises a clear error" do
    summary =
      run("""
      describe("q", function() {
        it("no db", function() {
          queryExecute("SELECT 1");
        });
      });
      """)

    assert summary.failed == 1
    assert [%{message: message}] = summary.results
    assert message =~ "query executor"
  end
end
