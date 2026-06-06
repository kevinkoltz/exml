defmodule ExML.CFScript.BIF.RegistryTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry

  test "resolves builtins case-insensitively across families" do
    assert Registry.builtin?("len")
    assert Registry.builtin?("LEN")
    assert Registry.builtin?("structKeyExists")
    assert Registry.builtin?("isNull")
    refute Registry.builtin?("not_a_function")
  end

  test "dispatches to the owning family" do
    assert Registry.call("ucase", ["hi"]) == "HI"
    assert Registry.call("len", ["hello"]) == 5
    assert Registry.call("isNull", [nil]) == true
    assert Registry.call("structKeyExists", [%{"a" => 1}, "A"]) == true
  end

  test "no two families claim the same name" do
    families = [
      ExML.CFScript.BIF.StringFns,
      ExML.CFScript.BIF.DecisionFns,
      ExML.CFScript.BIF.ListFns,
      ExML.CFScript.BIF.ArrayFns,
      ExML.CFScript.BIF.StructFns
    ]

    all = Enum.flat_map(families, & &1.names())
    assert all == Enum.uniq(all)
  end

  test "unknown function raises" do
    assert_raise ExML.CFScript.CFException, ~r/Undefined function/, fn ->
      Registry.call("bogus_fn", [])
    end
  end
end
