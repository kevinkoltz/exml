defmodule ExML.CFScript.BIF do
  @moduledoc """
  Behaviour for a family of CFML built-in functions (BIFs).

  CFML has ~200 BIFs spread across families (string, decision, list, array,
  struct, date, ...). Rather than one ever-growing `case`, each family is a
  module implementing this behaviour: `names/0` declares the (lowercased)
  function names it owns, and `call/2` evaluates one. `ExML.CFScript.BIF.Registry`
  aggregates the families into a single name → module table at compile time.

  This is the behaviour case from the hapi guides — a uniform contract with
  several interchangeable implementations, enforced by `@behaviour`/`@impl`,
  and open to new families without touching the dispatcher.

  Implementations receive names already downcased by the registry, so `call/2`
  clauses match lowercase. A family should provide a catch-all `call/2` clause
  that raises `ExML.CFScript.CFException` for unsupported arities.
  """

  @doc "The lowercased BIF names this family implements."
  @callback names() :: [String.t()]

  @doc "Evaluate the named BIF against a list of already-evaluated argument values."
  @callback call(name :: String.t(), args :: [any()]) :: any()
end
