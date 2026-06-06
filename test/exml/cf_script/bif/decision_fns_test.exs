defmodule ExML.CFScript.BIF.DecisionFnsTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R

  # Behavior verified against Lucee 6.2.5 op/Decision.java.

  describe "isNumeric (Lucee isNumber)" do
    test "real numbers and numeric strings" do
      assert R.call("isNumeric", [42])
      assert R.call("isNumeric", [3.5])
      assert R.call("isNumeric", ["42"])
      assert R.call("isNumeric", ["3.5"])
      assert R.call("isNumeric", ["+4"])
      assert R.call("isNumeric", ["-4"])
      assert R.call("isNumeric", [".5"])
      assert R.call("isNumeric", ["1e3"])
      assert R.call("isNumeric", ["  7 "])
    end

    test "non-numeric strings" do
      refute R.call("isNumeric", ["12abc"])
      refute R.call("isNumeric", ["1.5.6"])
      refute R.call("isNumeric", [""])
      refute R.call("isNumeric", ["."])
    end

    test "booleans are not numeric" do
      refute R.call("isNumeric", [true])
    end
  end

  describe "isBoolean (Lucee isBoolean)" do
    test "true/false/yes/no words, case-insensitive" do
      assert R.call("isBoolean", ["true"])
      assert R.call("isBoolean", ["FALSE"])
      assert R.call("isBoolean", ["Yes"])
      assert R.call("isBoolean", ["no"])
      assert R.call("isBoolean", [true])
    end

    test "numbers are not boolean" do
      refute R.call("isBoolean", [1])
      refute R.call("isBoolean", [0])
    end

    test "other strings are not boolean" do
      refute R.call("isBoolean", ["maybe"])
      refute R.call("isBoolean", ["t"])
    end
  end

  describe "type predicates" do
    test "isNull" do
      assert R.call("isNull", [nil])
      refute R.call("isNull", [""])
    end

    test "isArray / isStruct distinguish lists, maps, and components" do
      assert R.call("isArray", [[1, 2]])
      refute R.call("isArray", [%{}])
      assert R.call("isStruct", [%{"a" => 1}])
      refute R.call("isStruct", [[1]])
      refute R.call("isStruct", [%ExML.CFScript.Value.Instance{type_path: "cfc.x"}])
    end

    test "isSimpleValue" do
      assert R.call("isSimpleValue", ["hi"])
      assert R.call("isSimpleValue", [5])
      assert R.call("isSimpleValue", [true])
      refute R.call("isSimpleValue", [%{}])
      refute R.call("isSimpleValue", [[1]])
    end

    test "isEmpty" do
      assert R.call("isEmpty", [""])
      assert R.call("isEmpty", [[]])
      assert R.call("isEmpty", [%{}])
      refute R.call("isEmpty", ["x"])
      refute R.call("isEmpty", [[1]])
    end
  end
end
