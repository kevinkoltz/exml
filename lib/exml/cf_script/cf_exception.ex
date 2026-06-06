defmodule ExML.CFScript.CFException do
  @moduledoc """
  A CFML runtime error / thrown value.

  Carries a CFML exception `type` (e.g. `"AssertionError"`) alongside the
  message so `assert_*` failures and `throw(type=, message=)` can be told apart
  by the test harness.
  """

  defexception [:message, cf_type: "Application"]

  @type t :: %__MODULE__{message: String.t(), cf_type: String.t()}
end
