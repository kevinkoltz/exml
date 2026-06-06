defmodule ExML.CFScript.Builtins do
  @moduledoc """
  Facade over the CFML built-in function families.

  Resolution and dispatch live in `ExML.CFScript.BIF.Registry`, which
  aggregates the `ExML.CFScript.BIF` family modules. The interpreter and member
  call dispatch only need `builtin?/1` and `call/2`, so they go through here.
  """

  alias ExML.CFScript.BIF.Registry

  @doc "Whether `name` is a known built-in (case-insensitive)."
  @spec builtin?(String.t()) :: boolean()
  defdelegate builtin?(name), to: Registry

  @doc "Call a built-in by name with a list of already-evaluated argument values."
  @spec call(String.t(), [any()]) :: any()
  defdelegate call(name, args), to: Registry
end
