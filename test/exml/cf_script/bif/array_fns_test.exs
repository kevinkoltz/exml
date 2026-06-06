defmodule ExML.CFScript.BIF.ArrayFnsTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R

  # Behavior verified against Lucee 6.2.5 functions/arrays/*.java.

  test "arrayLen / arrayIsEmpty / arrayNew" do
    assert R.call("arrayLen", [[1, 2, 3]]) == 3
    assert R.call("arrayIsEmpty", [[]]) == true
    assert R.call("arrayIsEmpty", [[1]]) == false
    assert R.call("arrayNew", [1]) == []
  end

  test "arrayAppend / arrayPrepend (value-returning)" do
    assert R.call("arrayAppend", [[1, 2], 3]) == [1, 2, 3]
    assert R.call("arrayPrepend", [[2, 3], 1]) == [1, 2, 3]
  end

  test "arrayToList joins with delimiter (default comma)" do
    assert R.call("arrayToList", [[1, 2, 3]]) == "1,2,3"
    assert R.call("arrayToList", [["a", "b"], "|"]) == "a|b"
  end

  describe "arrayFind / arrayFindNoCase / arrayContains" do
    test "arrayFind is case-sensitive, 1-based, 0 when missing" do
      assert R.call("arrayFind", [["a", "b", "c"], "b"]) == 2
      assert R.call("arrayFind", [["a", "b"], "B"]) == 0
      assert R.call("arrayFind", [["a", "b"], "z"]) == 0
    end

    test "arrayFindNoCase ignores case" do
      assert R.call("arrayFindNoCase", [["a", "B"], "b"]) == 2
    end

    test "numeric elements compare numerically" do
      assert R.call("arrayFind", [[1, 2, 3], "2"]) == 2
    end
  end

  test "arraySum / arrayAvg / arrayMax / arrayMin" do
    assert R.call("arraySum", [[1, 2, 3, 4]]) == 10
    assert R.call("arrayAvg", [[2, 4]]) == 3.0
    assert R.call("arrayMax", [[3, 9, 1]]) == 9
    assert R.call("arrayMin", [[3, 9, 1]]) == 1
  end

  test "arrayReverse" do
    assert R.call("arrayReverse", [[1, 2, 3]]) == [3, 2, 1]
  end

  describe "arraySlice (Lucee semantics)" do
    test "offset and length" do
      assert R.call("arraySlice", [[1, 2, 3, 4, 5], 2, 2]) == [2, 3]
    end

    test "length 0 goes to end" do
      assert R.call("arraySlice", [[1, 2, 3, 4], 2]) == [2, 3, 4]
    end

    test "negative length trims from the end" do
      assert R.call("arraySlice", [[1, 2, 3, 4, 5], 1, -1]) == [1, 2, 3, 4]
    end

    test "negative offset counts from the end (start = size + offset)" do
      # offset -2 -> start index 5 + (-2) = 3, then to end
      assert R.call("arraySlice", [[1, 2, 3, 4, 5], -2]) == [3, 4, 5]
    end
  end

  test "arrayFirst / arrayLast error on empty array" do
    assert R.call("arrayFirst", [[1, 2]]) == 1
    assert R.call("arrayLast", [[1, 2]]) == 2
    assert_raise ExML.CFScript.CFException, fn -> R.call("arrayFirst", [[]]) end
  end
end
