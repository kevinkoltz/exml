defmodule ExmlTest do
  use ExUnit.Case
  doctest Exml

  test "greets the world" do
    assert Exml.hello() == :world
  end
end
