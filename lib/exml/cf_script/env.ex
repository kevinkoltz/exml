defmodule ExML.CFScript.Env do
  @moduledoc """
  An evaluation environment: the set of scopes visible while executing a
  statement, plus the shared interpreter context.

    * `arguments` — the current call's `arguments` scope
    * `local`     — the current call's `local` scope
    * `variables` — the component instance's shared `variables` scope
    * `this`      — the current component instance (or `nil` for static calls)
    * `default_scope` — where unscoped assignments land (`:local` | `:variables`)
    * `ctx`       — `ExML.CFScript.Context`, shared across the whole run
  """

  alias ExML.CFScript.Scope

  @type t :: %__MODULE__{
          arguments: Scope.t(),
          local: Scope.t(),
          variables: Scope.t(),
          this: term(),
          default_scope: :local | :variables,
          ctx: term()
        }

  defstruct [:arguments, :local, :variables, :this, :default_scope, :ctx]
end

defmodule ExML.CFScript.Context do
  @moduledoc """
  Run-wide interpreter context: where to find `.cfc` files, a cache of parsed
  components, and the registry of injected native functions
  (`describe`/`it`/`assert_*`/...).
  """

  @type t :: %__MODULE__{
          cfc_root: String.t(),
          cache: pid(),
          natives: %{optional(String.t()) => ExML.CFScript.Value.Native.t()}
        }

  defstruct cfc_root: nil, cache: nil, natives: %{}
end
