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

  @type query_result :: %{columns: [String.t()], rows: [[any()]]}
  @type t :: %__MODULE__{
          cfc_root: String.t(),
          cache: pid(),
          natives: %{optional(String.t()) => ExML.CFScript.Value.Native.t()},
          null_support: boolean(),
          query_executor: (String.t(), any() -> query_result()) | nil
        }

  # `null_support` mirrors Lucee's "full null support" application/server
  # setting. Signal runs with it OFF, which is the default here: accessing a
  # missing struct key or scope variable raises rather than yielding null.
  #
  # `query_executor` backs `queryExecute`/`<cfquery>`: a function
  # `(sql, params) -> %{columns: [...], rows: [[...]]}` (the shape of
  # `Macola.Repo.query/2`). When nil, query execution raises — the standalone
  # library has no database; the Phoenix app injects a Macola.Repo-backed one.
  defstruct cfc_root: nil, cache: nil, natives: %{}, null_support: false, query_executor: nil
end
