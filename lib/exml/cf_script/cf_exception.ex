defmodule ExML.CFScript.CFException do
  @moduledoc """
  A CFML runtime error / thrown value.

  Carries a CFML exception `type` (e.g. `"AssertionError"`) alongside the
  message so `assert_*` failures and `throw(type=, message=)` can be told apart
  by the test harness. `stack` is the CFML call stack (innermost first) captured
  as the exception crosses the first function-call boundary.
  """

  defexception [:message, cf_type: "Application", detail: "", stack: []]

  @type frame :: %{function: String.t(), source: String.t()}
  @type t :: %__MODULE__{
          message: String.t(),
          cf_type: String.t(),
          detail: String.t(),
          stack: [frame()]
        }
end
