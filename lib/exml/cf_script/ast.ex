defmodule ExML.CFScript.AST do
  @moduledoc """
  Struct definitions for the cfscript abstract syntax tree.

  These are produced by `ExML.CFScript.Parser` and consumed by
  `ExML.CFScript.Interpreter`. Expressions are represented as tagged tuples
  (see the moduledoc of `ExML.CFScript.Parser` for the full grammar) while the
  larger top-level declarations get named structs for readability.
  """

  defmodule Component do
    @moduledoc "A parsed CFC: an ordered list of member function declarations."
    @type t :: %__MODULE__{functions: [ExML.CFScript.AST.Function.t()], extends: String.t() | nil}
    defstruct functions: [], extends: nil
  end

  defmodule Function do
    @moduledoc "A `function` declaration with its params, modifiers, and body."
    @type t :: %__MODULE__{
            name: String.t(),
            params: [ExML.CFScript.AST.Param.t()],
            static: boolean(),
            localmode: boolean(),
            return_type: String.t() | nil,
            body: [tuple()]
          }
    defstruct name: nil, params: [], static: false, localmode: false, return_type: nil, body: []
  end

  defmodule Param do
    @moduledoc "A single function parameter."
    @type t :: %__MODULE__{
            name: String.t(),
            type: String.t() | nil,
            required: boolean(),
            default: tuple() | nil
          }
    defstruct name: nil, type: nil, required: false, default: nil
  end
end
