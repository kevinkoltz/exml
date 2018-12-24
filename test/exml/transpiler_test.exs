defmodule ExMLTranspilerTest do
  use ExUnit.Case

  @tag :skip
  test "static html" do
    html = "<h2>New Template</h2>\n"
    assert_transpiled(html, html)
  end

  test "static text" do
    assert_transpiled("foo bar", "foo bar")
  end

  test "variables" do
    # TODO: Mark if the variable is provided by assigns, or created within the
    # template. If the variable is created in the template, then @ macro prefix
    # is not used. Do this by marking the variable as as :assigns scope?? Also,
    # cfmodule will use attributes. We know if a variable is locally scoped if
    # it comes from an `item` attribute or the name of a query being looped
    # over.
    assert_transpiled("#foo#", "<%= foo %>")
    assert_transpiled("#foo.bar#", "<%= foo.bar %>")
    # TODO: concat variable parts and split on "." to separate scope
    # assert_transpiled("<%= foo_bar.salad =>", "#foo_bar.salad#")
  end

  test "comment" do
    assert_transpiled("<!--- salad --->", "<%# salad %>")
  end

  test "multiline comment" do
    assert_transpiled("<!---\n\nsalad\n\n--->", "<%#\n\nsalad\n\n%>")
  end

  test "comment and static text" do
    assert_transpiled("<!--- salad ---> bar", "<%# salad %> bar")
    assert_transpiled("foo <!--- salad --->", "foo <%# salad %>")
  end

  test "interpolation with bound variable from assigns" do
    assert_transpiled("foo #bar#", "foo <%= bar %>")
  end

  # TODO:
  # test "interpolation with bound variable from assigns" do
  #   assert_transpiled("foo #attributes.bar#", "foo <%= @bar %>")
  # end

  test "escaped hash" do
    assert_transpiled("foo ##bar", "foo #bar")
  end

  # TODO: find out how to make inner variable local (not prefixed with @)
  # test "cfloop list" do
  #   assert_transpiled(
  #     ~S(<cfloop list="#books#" item="book">#book#</cfloop>),
  #     ~S(<%= for book <- @books do %><%= book %><% end %>)
  #   )
  # end

  test "cfloop range" do
    assert_transpiled(
      ~S(<cfloop from="1" to="10" index="i">#i#</cfloop>),
      ~S(<%= for i <- 1..10 do %><%= i %><% end %>)
    )
  end

  # test "cfloop range with variables" do
  #   assert_transpiled(
  #     ~S(<cfloop from="#min#" to="#max#" index="i">#i#</cfloop>),
  #     ~S(hello)
  #   )
  # end

  # test "cfloop query" do
  #   assert_transpiled(
  #     ~S(<cfloop query="books">#books.title#</cfloop>),
  #     ~S(<%= for book <- @books do %><%= books.title %><% end %>)
  #   )
  # end

  # test "cfloop query with start and end" do
  #   expected = [
  #     cfloop_query: [
  #       query: "books",
  #       start_row: 1,
  #       end_row: 10,
  #       interpolation: ["books", "title"]
  #     ]
  #   ]

  # assert_transpiled(
  #   ~S(<cfloop query="books" start_row="1" end_row="10">#books.title#</cfloop>),
  #   expected
  # )

  #   assert_transpiled(
  #     ~S(<cfloop query="books" startRow="1" endRow="10">#books.title#</cfloop>),
  #     expected
  #   )
  # end

  # test "cfif" do
  #   assert_transpiled(~S(<cfif true>hello</cfif>), cfif: [expression: "true", static: "hello"])
  # end

  # test "cfif and cfelse" do
  #   assert_transpiled(
  #     ~S(<cfif true>a<cfelse>b</cfif>),
  #     [cfif: [expression: "true", static: "a", cfelse: [static: "b"]]]
  #   )
  # end

  # test "cfif, cfelse and cfelseif" do
  #   assert_transpiled(
  #     ~S(<cfif true>a<cfelseif 1 eq 2>b<cfelse>c</cfif>),
  #     [
  #       cfif: [
  #         expression: "true",
  #         static: "a",
  #         cfelseif: [expression: "1 eq 2", static: "b", cfelse: [static: "c"]]
  #       ]
  #     ]
  #   )
  # end

  defp assert_transpiled(source, expected) do
    {:ok, transpiled_source} = ExML.Transpiler.transpile(source)
    assert transpiled_source == expected
  end
end
