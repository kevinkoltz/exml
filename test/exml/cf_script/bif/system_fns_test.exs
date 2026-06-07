defmodule ExML.CFScript.BIF.SystemFnsTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R

  test "writeOutput / writeDump / dump are no-ops returning empty string" do
    assert R.call("writeOutput", ["anything"]) == ""
    assert R.call("writeOutput", []) == ""
    assert R.call("writeDump", [%{"a" => 1}]) == ""
    assert R.call("dump", [[1, 2, 3]]) == ""
    # named args are dropped before reaching a BIF, so a no-arg call is valid
    assert R.call("writeDump", []) == ""
  end
end
