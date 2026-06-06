defmodule ExML.CFScript.BIF.StringFnsTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R

  # Behavior verified against Lucee 6.2.5 sources (functions/string/*.java).

  describe "left/2 (Lucee Left.java)" do
    test "normal prefix" do
      assert R.call("left", ["hello", 2]) == "he"
    end

    test "count >= length returns the whole string" do
      assert R.call("left", ["hi", 5]) == "hi"
      assert R.call("left", ["hi", 2]) == "hi"
    end

    test "negative count returns length+count chars" do
      assert R.call("left", ["Peter", -1]) == "Pete"
    end

    test "abs(negative) >= length returns whole string" do
      assert R.call("left", ["hi", -5]) == "hi"
    end

    test "count of 0 raises" do
      assert_raise ExML.CFScript.CFException, ~r/can not be 0/, fn -> R.call("left", ["hi", 0]) end
    end
  end

  describe "right/2 (Lucee Right.java)" do
    test "normal suffix" do
      assert R.call("right", ["hello", 2]) == "lo"
    end

    test "count >= length returns whole string" do
      assert R.call("right", ["hi", 9]) == "hi"
    end

    test "negative count" do
      assert R.call("right", ["Peter", -1]) == "eter"
    end

    test "count of 0 raises" do
      assert_raise ExML.CFScript.CFException, fn -> R.call("right", ["hi", 0]) end
    end
  end

  describe "mid/3 (Lucee Mid.java)" do
    test "start and count" do
      assert R.call("mid", ["hello", 2, 3]) == "ell"
    end

    test "count omitted goes to end" do
      assert R.call("mid", ["hello", 3]) == "llo"
    end

    test "count -1 goes to end" do
      assert R.call("mid", ["hello", 2, -1]) == "ello"
    end

    test "count past end clamps" do
      assert R.call("mid", ["hello", 4, 99]) == "lo"
    end

    test "start past end returns empty" do
      assert R.call("mid", ["hello", 99, 2]) == ""
    end

    test "start < 1 raises" do
      assert_raise ExML.CFScript.CFException, ~r/must be a positive integer/, fn ->
        R.call("mid", ["hello", 0, 2])
      end
    end

    test "count < -1 raises" do
      assert_raise ExML.CFScript.CFException, fn -> R.call("mid", ["hello", 1, -2]) end
    end
  end

  describe "val/1 (Lucee ValNumber.getPos)" do
    test "leading integer" do
      assert R.call("val", ["1234 Main St."]) == 1234
      assert R.call("val", ["123T456"]) == 123
    end

    test "no leading number is zero" do
      assert R.call("val", ["Main St., 1234"]) == 0
      assert R.call("val", ["one"]) == 0
      assert R.call("val", [""]) == 0
    end

    test "decimals include the period" do
      assert R.call("val", ["123.456"]) == 123.456
      assert R.call("val", ["12.5x"]) == 12.5
    end

    test "leading sign is honored" do
      assert R.call("val", ["+4"]) == 4
      assert R.call("val", ["-4"]) == -4
    end

    test "leading dot" do
      assert R.call("val", [".5"]) == 0.5
    end

    test "trailing dot is dropped" do
      assert R.call("val", ["5."]) == 5
    end

    test "stops at the second dot" do
      assert R.call("val", ["1.5.6"]) == 1.5
    end
  end

  describe "find / findNoCase" do
    test "find is case-sensitive, 1-based, 0 when missing" do
      assert R.call("find", ["lo", "hello"]) == 4
      assert R.call("find", ["LO", "hello"]) == 0
      assert R.call("find", ["x", "hello"]) == 0
    end

    test "findNoCase ignores case" do
      assert R.call("findNoCase", ["LO", "hello"]) == 4
    end
  end

  describe "trim family and len" do
    test "trim/ltrim/rtrim" do
      assert R.call("trim", ["  hi  "]) == "hi"
      assert R.call("ltrim", ["  hi  "]) == "hi  "
      assert R.call("rtrim", ["  hi  "]) == "  hi"
    end

    test "len on string, array, struct" do
      assert R.call("len", ["hello"]) == 5
      assert R.call("len", [[1, 2, 3]]) == 3
      assert R.call("len", [%{"a" => 1}]) == 1
    end
  end
end
