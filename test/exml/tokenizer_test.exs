defmodule ExMLTokenizerTest do
  use ExUnit.Case

  test "static text" do
    assert_parsed([{:static, "foo bar"}], "foo bar")
  end

  @tag :skip
  # TODO: figure out why </h2> is not parsed as static.
  test "static html" do
    html = "<h2>New Template</h2>\n"
    assert_parsed([static: "<h2>", static: "New Template", static: "</h2>", static: "\n"], html)
  end

  @tag :skip
  test "static html with interpolation" do
    html = "<h2 #class#>Hello #world#</h2>\n"

    assert_parsed(
      [
        static: "<h2",
        interpolation: {"class"},
        static: ">",
        static: "Hello ",
        interpolation: {"world"},
        static: "</h2>",
        static: "\n"
      ],
      html
    )
  end

  test "variables" do
    assert_parsed([{:interpolation, {"foo"}}], "#foo#")
    # TODO: concat variable parts and split on "." to separate scope
    # assert_parsed([{:interpolation, ["foo", "bar"]}], "#foo.bar#")
    # assert_parsed([{:interpolation, ["foo_bar", "salad"]}], "#foo_bar.salad#")
  end

  test "comment" do
    assert_parsed([{:comment, " salad "}], "<!--- salad --->")
  end

  test "multiline comment" do
    assert_parsed([{:comment, "\n\nsalad\ndressing\n\n"}], "<!---\n\nsalad\ndressing\n\n--->")
  end

  test "comment and static text" do
    assert_parsed([{:comment, " salad "}, {:static, " bar"}], "<!--- salad ---> bar")
    assert_parsed([{:static, "foo "}, {:comment, " salad "}], "foo <!--- salad --->")
  end

  test "interpolation" do
    assert_parsed([{:static, "foo "}, {:interpolation, {"bar"}}], "foo #bar#")
  end

  test "escaped hash" do
    assert_parsed([{:static, "foo #bar"}], "foo ##bar")
  end

  test "cfloop list" do
    assert_parsed(
      [cfloop_list: [list: {:interpolation, {"books"}}, item: "book", interpolation: {"book"}]],
      ~S(<cfloop list="#books#" item="book">#book#</cfloop>)
    )
  end

  test "cfloop range" do
    assert_parsed(
      [cfloop_range: [from: 1, to: 10, index: "i", interpolation: {"i"}]],
      ~S(<cfloop from="1" to="10" index="i">#i#</cfloop>)
    )
  end

  test "cfloop range with variables" do
    assert_parsed(
      [
        cfloop_range: [
          from: {:interpolation, {"min"}},
          to: {:interpolation, {"max"}},
          index: "i",
          interpolation: {"i"}
        ]
      ],
      ~S(<cfloop from="#min#" to="#max#" index="i">#i#</cfloop>)
    )
  end

  test "cfloop query" do
    assert_parsed(
      [cfloop_query: [query: "books", interpolation: {"books", "title"}]],
      ~S(<cfloop query="books">#books.title#</cfloop>)
    )
  end

  test "cfloop query with start and end" do
    expected = [
      cfloop_query: [
        query: "books",
        start_row: 1,
        end_row: 10,
        interpolation: {"books", "title"}
      ]
    ]

    assert_parsed(
      expected,
      ~S(<cfloop query="books" start_row="1" end_row="10">#books.title#</cfloop>)
    )

    assert_parsed(
      expected,
      ~S(<cfloop query="books" startRow="1" endRow="10">#books.title#</cfloop>)
    )
  end

  test "cfif" do
    assert_parsed([cfif: [expression: "true", static: "hello"]], ~S(<cfif true>hello</cfif>))
  end

  test "cfif and cfelse" do
    assert_parsed(
      [cfif: [expression: "true", static: "a", cfelse: [static: "b"]]],
      ~S(<cfif true>a<cfelse>b</cfif>)
    )
  end

  test "cfif, cfelse and cfelseif" do
    assert_parsed(
      [
        cfif: [
          expression: "true",
          static: "a",
          cfelseif: [expression: "1 eq 2", static: "b", cfelse: [static: "c"]]
        ]
      ],
      ~S(<cfif true>a<cfelseif 1 eq 2>b<cfelse>c</cfif>)
    )
  end

  defp assert_parsed(expected, source) do
    {:ok, parsed, "", %{}, _, _} = ExML.Tokenizer.parse(source)
    assert parsed == expected
  end
end
