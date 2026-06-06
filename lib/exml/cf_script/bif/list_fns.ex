defmodule ExML.CFScript.BIF.ListFns do
  @moduledoc """
  CFML list built-in functions. A CFML "list" is a delimited string (default
  delimiter `,`). Implemented to Lucee 6.2 semantics in a later step; this is
  the family scaffold.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.CFException

  @impl true
  def names, do: []

  @impl true
  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end
end
