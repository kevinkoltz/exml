# exml — TODO

Roadmap for the cfscript interpreter (`lib/exml/cf_script`). Items are grouped
by area and roughly ordered by impact within each group.

## Parser / language features

- [x] **Statement-level parse recovery** — an unparseable statement becomes an
  `{:unsupported, reason}` marker (raises a loud, line-tagged `exml.unsupported`
  error if reached); the rest of the function still loads and runs.
- [x] **`do { } while ()`** loop.
- [x] **Inline param annotations** — `function f(numeric x hint="...")`. Trailing
  `key="value"` annotations after a parameter are parsed and ignored, so the
  function loads (type vs name is disambiguated by a type-keyword set).
- [x] **`<!--` / HTML comments** — blanked (line-neutral) alongside CFML
  `<!--- --->` comments.
- [x] **Top-level bare variable assignments** (pseudo-constructor) — `x = 5`,
  `x = {}`, `this.x = ...` directly in the component body now collect into
  `Component.init` and run per instance into the `variables` scope (before
  `init()`). Also fixed `this.x = v` assignment (was routed to a missing scope).

## Tag conversion coverage (`tag_converter.ex`)

Unsupported tags, unsupported `<cfloop>` forms, and unknown tag attributes now
load as `exml.unsupported` markers (assertive — they raise a specific error if
reached) instead of being silently dropped/ignored. Remaining work is to
actually *implement* these rather than mark them:

- [ ] **Stricter attribute-implementation flagging** — the per-tag allowed sets
  currently tolerate standard-but-unimplemented attributes (e.g. `<cfquery
  result=>`, `maxrows=`). Tighten to the genuinely-handled set once those are
  implemented, so the markers point only at real gaps.
- [x] **`<cfloop>` `collection=`/`condition=`** — converted (for-in over a
  struct / a while loop). `query=` keeps its current-row semantics so it stays a
  marker; `times=` still a marker.
- [x] **`<cfobject>` + `createObject(...)`** — instantiate a component
  (`name = new X()`); other object types (java/com) are markers.
- [x] **Top-level (pseudo-constructor) tags** — component-body tags outside any
  function are now converted too (e.g. `<cfobject>`/`<cfset>` memoization).
- [x] **Side-effect / IO tags & `<cfmodule>`** — `<cffile>`, `<cfhttp>`,
  `<cfthread>`, `<cfftp>`, `<cfmodule>` (custom tags), ... become per-statement
  `exml.unsupported` markers, so the function loads and only the IO line raises.
  Genuinely *running* these (filesystem/network/custom-tag templates) is out of
  scope for the interpreter.
- [x] **`cfc.x = createObject(...)` namespace-cache pattern** — `cfc.x` member
  access/assignment now uses a `cfc` cache struct in the variables scope (the
  CFML memoization idiom), while `new cfc.X()` / `cfc.X::m` still use the path,
  matching how CFML disambiguates member access from path syntax.
- [ ] **Stricter attribute-implementation flagging** — the per-tag allowed sets
  currently tolerate standard-but-unimplemented attributes (e.g. `<cfquery
  result=>`, `maxrows=`). Tighten to the genuinely-handled set once those are
  implemented, so the markers point only at real gaps.

## Diagnostics & tooling

- [ ] **(Lower priority) Per-closure call-stack frames** — a closure body
  (e.g. an `it` callback) currently updates its *enclosing* function's frame
  line rather than pushing its own frame. Backtrace lines stay accurate, but
  deeply-nested closure call sites attribute to the nearest named function
  instead of showing a distinct frame. Push a frame in `Interpreter.invoke/3`
  for `%Closure{}` (with a sensible label) if we want per-closure frames.

## Runtime / scopes / BIFs

- [ ] **`client` / `session` scopes** — not modelled (only request/application/
  cgi/server/url/form are seeded).
- [ ] **Timezone-aware `dateConvert`** — dates are timezone-naive today.
- [ ] **Wider BIF coverage** — add string/date/list/struct/math BIFs as specs
  require them.

## Integration (hapi side)

- [ ] **End-to-end run of `mix hapi.signal.test`** — the formatter is wired in,
  but a full run needs `mix deps.get` in the `hapi-exml-signal-test` worktree
  (only syntax-checked so far).

## Spec coverage sweep

- [ ] **`route_events_empty_build_ids_spec`** — 2/4; the remaining two need
  `<cfmodule>` + a `<cfloop>` query form (see above).
- [ ] **`promise_date_granularity_blank_spec`** — needs a live `request.mbx_db_name`
  DB scope, so it runs via the hapi `SpecRunner` against Macola (use a stub or a
  small fixture to keep DB load low).
- [ ] **Broaden the spec sweep** — run the remaining `test/specs/*_spec.cfc`
  through the runner, fixing parser/BIF gaps as they surface (skip DB-heavy
  specs or stub their queries).
