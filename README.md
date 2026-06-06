# ExML

ExML is an Elixir implementation of CFML (ColdFusion Markup Language). It has
two parts:

* **Tag transpiler** (`ExML.Tokenizer` / `ExML.Transpiler`) — compiles CFML tag
  markup (`<cfif>`, `<cfloop>`, `#interpolation#`) into EEx.
* **cfscript interpreter** (`ExML.CFScript.*`) — a tree-walking interpreter for
  cfscript. Its purpose is to run [Signal](https://gitlab.com/ahd-hydra/software/signal)'s
  CFML test specs from Elixir (e.g. from a Phoenix project) without a running
  Lucee/ColdFusion server.

## Running Signal specs

The interpreter loads real `.cfc` components from a `--cfc-root` and runs a spec
file. The spec's `describe`/`it`/`assert_*` calls are served by native Elixir
functions (`ExML.CFScript.Runner`) instead of the HTML-emitting
`test_framework.cfc`, so results come back as plain data.

```sh
mix exml.signal.test common_spec \
  --cfc-root ../signal/cfc \
  --spec-root ../signal/test/specs
```

```elixir
ExML.CFScript.run_spec("../signal/test/specs/common_spec.cfc", cfc_root: "../signal/cfc")
#=> %{passed: 3, failed: 0, total: 3, results: [...]}
```

### Pipeline

`source → ExML.CFScript.Lexer → ExML.CFScript.Parser (AST) → ExML.CFScript.Interpreter`

The `Loader` unwraps the tag shell (`<cfcomponent>`/`<cfscript>`/`<cffunction>`)
and parses CFCs **function-by-function**, skipping (with a logged warning) any
function using cfscript features not yet supported — so unsupported siblings
don't sink a component.

### Supported so far

Components and function declarations (incl. `static`, return types,
`localmode`), `if`/`else`, `return`, `var`, assignments, the full operator set
(`&`, comparisons, `and`/`or`/`not`, arithmetic), member access (`a.b`), static
calls (`cfc.x::y()`), instance/method dispatch, `new`, string member functions
(`s.trim()`), anonymous-function closures, and a starter set of BIFs (`len`,
`ucase`, `left`, `right`, `mid`, `trim`, `structKeyExists`, `isNull`,
`isSimpleValue`, `findNoCase`, `refind`, ...).

## Goals / roadmap

* Array and struct literals, `for`/`for-in`/`while` loops, ternary, `assert_throws`
  (needed to run the larger monolithic specs end-to-end)
* Statement-level parse recovery (skip an unsupported statement, keep the rest)
* Support pattern matching in expressions
* Add `<cfunless>`

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