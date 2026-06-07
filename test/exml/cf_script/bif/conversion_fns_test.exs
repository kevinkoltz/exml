defmodule ExML.CFScript.BIF.ConversionFnsTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R

  # Behavior verified against Lucee 6.2.5 (functions/other/*, operators).

  describe "int / fix (truncate toward zero)" do
    test "drops the fractional part of a positive number" do
      assert R.call("int", [2.9]) == 2
      assert R.call("int", ["3.75"]) == 3
    end

    test "truncates toward zero for negatives" do
      assert R.call("int", [-1.5]) == -1
      assert R.call("fix", [-1.5]) == -1
    end
  end

  describe "floor / ceiling / round / abs" do
    test "floor rounds down, ceiling rounds up" do
      assert R.call("floor", [-1.5]) == -2
      assert R.call("ceiling", [1.1]) == 2
    end

    test "round to nearest, abs magnitude" do
      assert R.call("round", [2.5]) == 3
      assert R.call("abs", [-4]) == 4
    end
  end

  describe "toString" do
    test "renders a number as its string form" do
      assert R.call("tostring", [5]) == "5"
      assert R.call("tostring", ["hi"]) == "hi"
    end
  end
end
