# ExML

ExML is an Elixir implementation of CFML (ColdFusion Markup Language). It has
two parts:

* **Tag transpiler** (`ExML.Tokenizer` / `ExML.Transpiler`) — compiles CFML tag
  markup (`<cfif>`, `<cfloop>`, `#interpolation#`) into EEx.
* **cfscript interpreter** (`ExML.CFScript.*`) — a tree-walking interpreter for
  cfscript. Its purpose is to run a CFML codebase's test specs from Elixir
  (e.g. from a Phoenix project) without a running Lucee/ColdFusion server.

## Running CFML specs

The interpreter loads real `.cfc` components from a `--cfc-root` and runs a spec
file. The spec's `describe`/`it`/`assert_*` calls are served by native Elixir
functions (`ExML.CFScript.Runner`) instead of the HTML-emitting
`test_framework.cfc`, so results come back as plain data.

```sh
mix exml.test common_spec \
  --cfc-root path/to/cfc \
  --spec-root path/to/specs
```

```elixir
ExML.CFScript.run_spec("path/to/specs/common_spec.cfc", cfc_root: "path/to/cfc")
#=> %{passed: 3, failed: 0, total: 3, results: [...]}
```

### Pipeline

`source → ExML.CFScript.Lexer → ExML.CFScript.Parser (AST) → ExML.CFScript.Interpreter`

The `Loader` unwraps the tag shell (`<cfcomponent>`/`<cfscript>`/`<cffunction>`)
and parses CFCs **function-by-function**, skipping (with a logged warning) any
function using cfscript features not yet supported — so unsupported siblings
don't sink a component.

### Language features

Components and function declarations (incl. `static`, return types,
`localmode`), `if`/`else`, `return`, `var`, `for`/`for-in`/`while`,
`try`/`catch`/`finally` + `throw`, assignments, the full operator set
(`&`, comparisons, `and`/`or`/`not`, arithmetic), member access (`a.b`), static
calls (`cfc.x::y()`), instance/method dispatch, `new`, array literals `[…]`,
struct literals `{k: v}`, anonymous-function closures, arrow functions,
positional and **named** arguments (`fn(x = 1)`), string interpolation, and
member functions on strings/arrays/structs (`s.trim()`, `a.map(fn)`,
`s.keyExists(k)`).

### Built-in functions

BIFs are organized into families behind the `ExML.CFScript.BIF` behaviour,
aggregated by `ExML.CFScript.BIF.Registry`. They are ported 1:1 from the
Lucee 6.2.5 sources and scoped to what a real CFML codebase uses:

* **String** — `len`, `ucase`, `lcase`, `ucfirst`, `left`, `right`, `mid`,
  `trim`, `ltrim`, `rtrim`, `find`, `findNoCase`, `reFind`, `reverse`,
  `repeatString`, `val`
* **Decision** — `isNull`, `isNumeric`, `isBoolean`, `isSimpleValue`,
  `isArray`, `isStruct`, `isEmpty`, `isDefined`, `isObject`, `isQuery`
* **List** (delimited strings) — `listLen`, `listFind`, `listFindNoCase`,
  `listContains`, `listAppend`, `listPrepend`, `listToArray`, `listGetAt`,
  `listFirst`, `listLast`, `listRest`
* **Array** — `arrayLen`, `arrayNew`, `arrayIsEmpty`, `arrayAppend`,
  `arrayPrepend`, `arrayToList`, `arrayFind(NoCase)`, `arrayContains`,
  `arraySlice`, `arrayReverse`, `arrayFirst`, `arrayLast`, `arraySum`,
  `arrayAvg`, `arrayMax`, `arrayMin`
* **Struct** — `structKeyExists`, `structNew`, `structCount`, `structIsEmpty`,
  `structKeyArray`, `structKeyList`, `structInsert`, `structAppend`,
  `structDelete`, `structUpdate`, `structCopy`
* **Query** — `queryNew`, `queryAddRow`, `querySetCell`, `queryAddColumn`,
  `queryColumnData`, `queryColumnList`, `queryRecordCount`, `queryGetRow`,
  `queryColumnExists`, `valueList`, `valueArray`, plus `q.recordCount`,
  `q.columnList`, and `q.column[row]` access
* **Date** — `now`, `createDate`, `createTime`, `createDateTime`,
  `createTimeSpan`, `year`/`month`/`day`/`hour`/`minute`/`second`/`quarter`/
  `week`/`dayOfYear`/`daysInMonth`/`dayOfWeek`, `dateAdd`, `dateDiff`,
  `datePart`, `dateCompare`, `dateFormat`, `timeFormat`, `dateTimeFormat`,
  `parseDateTime`. Dates are timezone-naive `NaiveDateTime`; numeric coercion is
  the CFML date serial (so dates compare/order numerically). `dateConvert` is a
  pass-through (no timezone shift).
* **Higher-order** (`ExML.CFScript.HigherOrder`, take UDF callbacks) —
  `arrayMap/Filter/Reduce/Each/Some/Every` and `structEach/Map/Filter/Reduce`

Lucee nuances are matched exactly and covered by tests, e.g. `left/right` error
on count 0 and return the whole string when `abs(count) >= length`; `val`
follows `ValNumber.getPos`; lists ignore empty elements by default; `isBoolean`
rejects numbers; string→boolean coercion throws for `""`.

### Reference types

Arrays and structs are **reference types**, matching Lucee: `b = a` aliases the
same collection, passing one to a function shares it, and `arr.append(x)` /
`struct.key = v` / `arr[i] = v` mutate in place. The bare mutators
(`arrayAppend`, `structInsert`, ...) return `true`; their member forms return
the receiver for chaining (`arr.append(x).append(y)`), per Lucee's
`<member-chaining>` flags. `duplicate()` makes a deep copy that shares nothing
mutable. References are heap-backed (`ExML.CFScript.Heap`); the
`ExML.CFScript.Collections` boundary derefs at the BIF edge so the families
stay pure.

### Queries and `queryExecute`

Queries are a reference type (`queryNew`/`queryAddRow`/`querySetCell` mutate in
place). `queryExecute(sql, params, options)` runs SQL through a **pluggable
executor** — a `Context.query_executor` / `:query_executor` Runner option shaped
like `Ecto.Repo.query/2` (`(sql, params) -> %{columns: [...], rows: [[...]]}`).
The standalone library has no database, so without an executor it raises; a host
application injects a repo-backed one. `options` supports `returnType` `"query"`
(default) and `"array"` (array of row structs).

### Predefined scopes

The interpreter does not run the `Application.cfc` request lifecycle, so the
run-wide CFML scopes it would populate (`request`, `application`, `cgi`,
`server`, `url`, `form`) are instead **seeded by the host** via the `:scopes`
Runner option, e.g. `%{"request" => %{"db_name" => "appdb"}}`. They are
readable and writable (`request.flash = "x"`) and live for the run. Unqualified
reads do not fall through to these scopes (no scope-hunt). `client`/`session`
are not modelled yet.

### Null support

`isNull`/missing-key behavior follows Lucee's full-null-support setting via a
`Context.null_support` flag (and `:null_support` Runner option). It defaults to
**off** (a common Lucee configuration): reading a missing struct/scope key
raises rather than yielding null.

## Goals / roadmap

* `switch`/`case`, ternary `?:` / elvis, `do/while`
* `<cfquery>` tag (script world uses `queryExecute`; the tag matters once
  tag-based `<cffunction>` bodies are interpreted)
* Statement-level parse recovery (skip an unsupported statement, keep the rest)
* Timezone-aware `dateConvert` (currently a pass-through)
* `client`/`session` scopes; a wider tail of BIFs

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `exml` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:exml, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/exml](https://hexdocs.pm/exml).

## License

"ExML" is released under the [Apache 2 License](LICENSE)