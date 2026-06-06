defmodule ExML.CFScript.ValueTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.Value
  alias ExML.CFScript.Value.{Closure, Instance}

  describe "to_str/1" do
    test "numbers print without trailing .0 for whole floats" do
      assert Value.to_str(1) == "1"
      assert Value.to_str(1.0) == "1"
      assert Value.to_str(3.5) == "3.5"
    end

    test "booleans and null" do
      assert Value.to_str(true) == "true"
      assert Value.to_str(false) == "false"
      assert Value.to_str(nil) == ""
    end

    test "complex values raise, as Lucee does" do
      assert_raise ExML.CFScript.CFException, ~r/Struct to String/, fn -> Value.to_str(%{"a" => 1}) end
      assert_raise ExML.CFScript.CFException, ~r/Array to String/, fn -> Value.to_str([1, 2]) end
    end
  end

  describe "truthy?/1" do
    test "boolean-ish strings" do
      assert Value.truthy?("true")
      assert Value.truthy?("YES")
      refute Value.truthy?("false")
      refute Value.truthy?("no")
    end

    test "empty and non-boolean strings throw, matching Lucee" do
      assert_raise ExML.CFScript.CFException, fn -> Value.truthy?("") end
      assert_raise ExML.CFScript.CFException, fn -> Value.truthy?("maybe") end
    end

    test "numeric strings and numbers" do
      assert Value.truthy?("1")
      assert Value.truthy?(2)
      refute Value.truthy?(0)
      refute Value.truthy?("0")
    end

    test "non-boolean, non-numeric string raises" do
      assert_raise ExML.CFScript.CFException, fn -> Value.truthy?("hello") end
    end
  end

  describe "as_number/1 and to_number/1" do
    test "parses integers and floats from strings" do
      assert Value.as_number("42") == {:ok, 42}
      assert Value.as_number("3.5") == {:ok, 3.5}
      assert Value.as_number("  7 ") == {:ok, 7}
      assert Value.as_number("12abc") == :error
    end

    test "to_number raises on non-numeric" do
      assert Value.to_number("5") == 5
      assert_raise ExML.CFScript.CFException, fn -> Value.to_number("abc") end
    end
  end

  describe "equals?/2 (CFML loose equality)" do
    test "numeric coercion across string/number" do
      assert Value.equals?(1, "1")
      assert Value.equals?("2.0", 2)
      refute Value.equals?(1, 2)
    end

    test "case-insensitive string comparison" do
      assert Value.equals?("Hello", "hello")
      refute Value.equals?("Hello", "world")
    end
  end

  describe "compare/2" do
    test "numeric ordering" do
      assert Value.compare(1, 2) == :lt
      assert Value.compare(5, 5) == :eq
      assert Value.compare("10", 9) == :gt
    end

    test "string ordering is case-insensitive" do
      assert Value.compare("apple", "Banana") == :lt
    end
  end

  describe "type_name/1 and simple?/1" do
    test "labels primitives and complex values" do
      assert Value.type_name("x") == :string
      assert Value.type_name(1) == :number
      assert Value.type_name(true) == :boolean
      assert Value.type_name(nil) == :null
      assert Value.type_name(%{}) == :struct
      assert Value.type_name([]) == :array
      assert Value.type_name(%Closure{}) == :function
    end

    test "simple? only for string/number/boolean" do
      assert Value.simple?("x")
      assert Value.simple?(3)
      refute Value.simple?(%{})
      refute Value.simple?([1])
    end
  end

  describe "display/1 never raises" do
    test "labels complex values instead of raising" do
      assert Value.display(%{"a" => 1}) =~ "struct"
      assert Value.display([1, 2, 3]) =~ "array"
      assert Value.display(%Instance{type_path: "cfc.foo"}) =~ "cfc.foo"
      assert Value.display("hi") == "hi"
    end
  end
end
