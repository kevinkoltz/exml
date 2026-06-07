defmodule ExML.CFScript.BIF.ListFnsTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R

  # Behavior verified against Lucee 6.2.5 type/util/ListUtil.java.

  describe "listLen" do
    test "counts elements, ignoring empty fields by default" do
      assert R.call("listLen", ["a,b,c"]) == 3
      assert R.call("listLen", ["a,,b"]) == 2
      assert R.call("listLen", [""]) == 0
    end

    test "honors a custom delimiter set" do
      assert R.call("listLen", ["a;b|c", ";|"]) == 3
    end
  end

  describe "listFind / listFindNoCase" do
    test "1-based index, case-sensitive, 0 when missing" do
      assert R.call("listFind", ["a,b,c", "b"]) == 2
      assert R.call("listFind", ["a,b,c", "B"]) == 0
      assert R.call("listFind", ["a,b,c", "x"]) == 0
    end

    test "indexes are over non-empty elements" do
      assert R.call("listFind", ["a,,c", "c"]) == 2
    end

    test "no trimming of elements" do
      assert R.call("listFind", ["a, b", "b"]) == 0
    end

    test "listFindNoCase ignores case" do
      assert R.call("listFindNoCase", ["a,b,c", "B"]) == 2
    end
  end

  describe "listContains" do
    test "matches the first element containing the substring" do
      assert R.call("listContains", ["apple,banana,cherry", "an"]) == 2
      assert R.call("listContains", ["apple,banana", "z"]) == 0
    end
  end

  describe "listAppend / listPrepend" do
    test "append" do
      assert R.call("listAppend", ["a,b", "c"]) == "a,b,c"
      assert R.call("listAppend", ["", "c"]) == "c"
    end

    test "prepend" do
      assert R.call("listPrepend", ["b,c", "a"]) == "a,b,c"
    end

    test "custom delimiter uses its first char as separator" do
      assert R.call("listAppend", ["a;b", "c", ";"]) == "a;b;c"
    end
  end

  describe "listToArray" do
    test "splits, ignoring empties" do
      assert R.call("listToArray", ["a,b,c"]) == ["a", "b", "c"]
      assert R.call("listToArray", ["a,,b"]) == ["a", "b"]
      assert R.call("listToArray", [""]) == []
    end
  end

  describe "listGetAt / listFirst / listLast / listRest" do
    test "getAt is 1-based over non-empty elements" do
      assert R.call("listGetAt", ["a,b,c", 2]) == "b"
      assert R.call("listGetAt", ["a,,c", 2]) == "c"
    end

    test "getAt out of range raises" do
      assert_raise ExML.CFScript.CFException, ~r/invalid string list index/, fn ->
        R.call("listGetAt", ["a,b", 5])
      end
    end

    test "first / last / rest" do
      assert R.call("listFirst", ["a,b,c"]) == "a"
      assert R.call("listLast", ["a,b,c"]) == "c"
      assert R.call("listRest", ["a,b,c"]) == "b,c"
      assert R.call("listRest", ["a"]) == ""
    end

    test "sort numeric / textnocase / order" do
      assert R.call("listSort", ["10,2,1", "numeric"]) == "1,2,10"
      assert R.call("listSort", ["b,A,c", "textnocase"]) == "A,b,c"
      assert R.call("listSort", ["1,2,3", "numeric", "desc"]) == "3,2,1"
    end
  end
end
