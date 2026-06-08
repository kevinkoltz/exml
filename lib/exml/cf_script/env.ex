defmodule ExML.CFScript.Env do
  @moduledoc """
  An evaluation environment: the set of scopes visible while executing a
  statement, plus the shared interpreter context.

    * `arguments` — the current call's `arguments` scope
    * `local`     — the current call's `local` scope
    * `variables` — the component instance's shared `variables` scope
    * `this`      — the current component instance (or `nil` for static calls)
    * `default_scope` — where unscoped assignments land (`:local` | `:variables`)
    * `static_scope` — the component's shared `static` scope
    * `component`  — the `AST.Component` currently executing (for sibling-method
      resolution, including from static methods where `this` is nil)
    * `type_path`  — the component's path (keys its static scope)
    * `enclosing`  — captured `local` scopes of lexically-enclosing functions
      (a closure can read its defining function's locals); innermost first
    * `template_dir` — directory of the `.cfm` file currently rendering, so a
      relative `<cfinclude>`/`<cfmodule>` resolves against the right folder
    * `attributes` — a custom tag's (`<cfmodule>`) `attributes` scope (else nil)
    * `caller`     — a custom tag's `caller` scope: the *invoking* page's
      `variables` ref, so the tag can read/write `caller.*` (else nil)
    * `ctx`       — `ExML.CFScript.Context`, shared across the whole run
  """

  alias ExML.CFScript.Scope

  @type t :: %__MODULE__{
          arguments: Scope.t(),
          local: Scope.t(),
          variables: Scope.t(),
          this: term(),
          default_scope: :local | :variables,
          static_scope: Scope.t() | nil,
          component: term(),
          type_path: String.t() | nil,
          enclosing: [Scope.t()],
          template_dir: String.t() | nil,
          attributes: Scope.t() | nil,
          caller: Scope.t() | nil,
          ctx: term()
        }

  defstruct [
    :arguments,
    :local,
    :variables,
    :this,
    :default_scope,
    :static_scope,
    :component,
    :type_path,
    {:enclosing, []},
    :template_dir,
    :attributes,
    :caller,
    :ctx
  ]
end

defmodule ExML.CFScript.Context do
  @moduledoc """
  Run-wide interpreter context: where to find `.cfc` files, a cache of parsed
  components, and the registry of injected native functions
  (`describe`/`it`/`assert_*`/...).
  """

  @type query_result :: %{columns: [String.t()], rows: [[any()]]}
  @type http_request :: %{method: String.t(), url: String.t(), params: [map()], options: map()}
  @type t :: %__MODULE__{
          cfc_root: String.t(),
          cache: pid(),
          natives: %{optional(String.t()) => ExML.CFScript.Value.Native.t()},
          null_support: boolean(),
          query_executor:
            (String.t(), any() -> query_result())
            | (String.t(), any(), map() -> query_result())
            | nil,
          http_executor: (http_request() -> map()) | nil,
          output: pid() | nil,
          template_root: String.t() | nil,
          scopes: %{optional(String.t()) => reference()}
        }

  # `null_support` mirrors Lucee's "full null support" application/server
  # setting (commonly OFF, the default here): accessing a
  # missing struct key or scope variable raises rather than yielding null.
  #
  # `query_executor` backs `queryExecute`/`<cfquery>`: a function
  # `(sql, params) -> %{columns: [...], rows: [[...]]}` (the shape of
  # `Ecto.Repo.query/2`). When nil, query execution raises — the standalone
  # library has no database; the Phoenix app injects an Ecto repo-backed one.
  #
  # `scopes` holds the run-wide predefined CFML scopes (`request`,
  # `application`, `cgi`, ...) as mutable `Scope` refs, seeded by the host —
  # since the interpreter does not run the `Application.cfc` request lifecycle
  # that would normally populate them. (`client`/`session` are not modelled.)
  # `http_executor` backs `<cfhttp>` / the cfscript `cfhttp(...) { cfhttpparam }`
  # form: a function `(%{method:, url:, params:, options:}) -> response map`. When
  # nil, an HTTP call raises — the standalone library has no HTTP client; a host
  # (e.g. the Phoenix app) injects a `Req`-backed one.
  #
  # `output` is the `ExML.CFScript.OutputBuffer` pid backing `.cfm` template
  # rendering — `writeOutput`/literal text/`<cfoutput>` append to it. When nil
  # (the spec-runner case), `writeOutput` is a no-op, as before.
  #
  # `template_root` is the web root (`SignalWeb`) that absolute `<cfinclude
  # template="/...">` paths resolve against; relative paths use the rendering
  # file's directory (`Env.template_dir`).
  defstruct cfc_root: nil,
            cache: nil,
            natives: %{},
            null_support: false,
            query_executor: nil,
            http_executor: nil,
            output: nil,
            template_root: nil,
            scopes: %{}
end
