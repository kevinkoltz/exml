defmodule ExML.Tokenizer.Helpers do
  import NimbleParsec

  # escaped hash, to prevent interpolation
  def escaped_hash, do: times(ascii_char([?#]), 2) |> replace(?#)

  def whitespace, do: ascii_string([?\n, ?\t, ?\s], min: 1)

  def single_or_double_quote, do: ascii_char([?", ?'])
end

defmodule ExML.Tokenizer.Attribute do
  import NimbleParsec
  import ExML.Tokenizer.Helpers

  @type combinator :: NimbleParsec.t()

  @default_attribute_opts %{
    # Other value parsers include: :integer, :variable
    value_parsers: [:interpolation],
    allow_pascal_case: false
  }

  def equal_sign do
    optional(ignore(whitespace()))
    |> string("=")
    |> optional(ignore(whitespace()))
  end

  @spec parse(String.t(), Keyword.t()) :: combinator
  def parse(name, opts \\ [])

  def parse(name, opts) when is_binary(name) do
    %{
      value_parsers: value_parsers,
      allow_pascal_case: allow_pascal_case
    } = Enum.into(opts, @default_attribute_opts)

    tag = attribute_tag(name, allow_pascal_case)
    attribute_name = attribute_name(tag, allow_pascal_case)

    ignore(attribute_name)
    |> ignore(single_or_double_quote())
    |> attribute_value(value_parsers)
    |> ignore(single_or_double_quote())
    |> unwrap_and_tag(String.to_atom(tag))
  end

  @spec attribute_value(combinator, [Atom.t()]) :: combinator
  defp attribute_value(combinator, [value_parser]) when is_atom(value_parser) do
    parsec(combinator, value_parser)
  end

  defp attribute_value(combinator, value_parsers) when is_list(value_parsers) do
    choices = Enum.map(value_parsers, &parsec(&1))
    choice(combinator, choices)
  end

  defp attribute_tag(name, true = _allow_pascal_case) do
    Macro.underscore(name)
  end

  defp attribute_tag(name, false = _allow_pascal_case), do: name

  defp attribute_name(name, true = _allow_pascal_case) do
    pascalized = pascal_case(name)

    [
      string(name),
      string(pascalized)
    ]
    |> choice()
    |> concat(equal_sign())
  end

  defp attribute_name(name, false = _allow_pascal_case) do
    name
    |> string()
    |> concat(equal_sign())
  end

  # Convert a string to pascalCase.
  # To support legacy pascal cased attribute names (e.g. startRow)
  defp pascal_case(string) do
    {head, tail} =
      string
      |> Macro.camelize()
      |> String.split_at(1)

    String.downcase(head) <> tail
  end
end

defmodule ExML.Tokenizer.Tag do
  import NimbleParsec
  import ExML.Tokenizer.Helpers

  alias ExML.Tokenizer.Attribute

  @type combinator :: NimbleParsec.t()

  # TODO: add doctests and document tag usage

  ### <cfloop list="#books#" item="book">#book#</cfloop>
  def cfloop_list do
    attributes = [
      Attribute.parse("list", value_parsers: [:interpolation]),
      Attribute.parse("item", value_parsers: [:variable])
    ]

    parse_tag("cfloop", :cfloop_list, attributes)
  end

  ### <cfloop from="1" to="10" index="i">#i#</cfloop>
  ### <cfloop from="#min#" to="#max#" index="i">#i#</cfloop>
  def cfloop_range do
    attributes = [
      Attribute.parse("from", value_parsers: [:integer, :interpolation]),
      Attribute.parse("to", value_parsers: [:integer, :interpolation]),
      Attribute.parse("index", value_parsers: [:variable])
    ]

    parse_tag("cfloop", :cfloop_range, attributes)
  end

  ### <cfloop query="#books#">#books.title#</cfloop>
  ### <cfloop query="#books#" startRow="5" endRow="10">#books.title#</cfloop>
  ### Legacy support:
  ### <cfloop query="books">#books.title#</cfloop>
  def cfloop_query do
    attributes = [
      # cfquery allows implicit variable interpolation, but this also adds normal interpolation for consistency
      Attribute.parse("query", value_parsers: [:variable, :interpolation]),
      Attribute.parse("start_row",
        value_parsers: [:integer, :interpolation],
        allow_pascal_case: true
      ),
      Attribute.parse("end_row",
        value_parsers: [:integer, :interpolation],
        allow_pascal_case: true
      )
    ]

    parse_tag("cfloop", :cfloop_query, attributes)
  end

  def cfif do
    ignore(string("<cfif"))
    |> optional(ignore(whitespace()))
    |> parsec(:expression)
    |> ignore(string(">"))
    |> parsec(:parse)
    |> ignore(string("</cfif>"))
    |> tag(:cfif)
  end

  def cfelse do
    ignore(string("<cfelse>"))
    |> repeat(lookahead_not(string("</cfif>")) |> parsec(:parse))
    |> tag(:cfelse)
  end

  def cfelseif do
    ignore(string("<cfelseif"))
    |> optional(ignore(whitespace()))
    |> parsec(:expression)
    |> ignore(string(">"))
    |> repeat(lookahead_not(string("</cfif>")) |> parsec(:parse))
    |> tag(:cfelseif)
  end

  @spec parse_tag(String.t(), Atom.t(), [attribute :: combinator]) :: combinator
  def parse_tag(name, tag, attributes) do
    ignore(string("<#{name}"))
    |> ignore(whitespace())
    |> repeat(choice([ignore(whitespace()) | attributes]))
    |> ignore(string(">"))
    |> parsec(:parse)
    |> ignore(string("</#{name}>"))
    |> tag(tag)
  end
end

defmodule ExML.Tokenizer do
  @moduledoc """
  Parses ExML into tokens which are later used for compilation.
  """

  import NimbleParsec
  import ExML.Tokenizer.Helpers

  alias ExML.Tokenizer.Attribute
  alias ExML.Tokenizer.Tag

  # TODO: check if other unicode characters are allowed
  # TODO: explicitly split variable up by scope (e.g. {scope: "books", variable: "title"})
  defcombinatorp(
    :variable,
    ascii_string([?a..?z, ?A..?Z], min: 1)
    |> optional(
      repeat(
        choice([
          ignore(string(".")),
          utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 1)
        ])
      )
    )
  )

  defcombinatorp(:integer, integer([], min: 1))

  defcombinatorp(
    :interpolation,
    ignore(ascii_char([?#]))
    |> parsec(:variable)
    |> ignore(ascii_char([?#]))
    # TODO: explicitly return the scope (e.g. {"books", "title"} or
    # {"assigns", "books"})
    |> reduce({List, :to_tuple, []})
    |> unwrap_and_tag(:interpolation)
  )

  comment =
    ignore(string("<!---"))
    |> repeat(
      lookahead_not(string("--->"))
      |> choice([
        utf8_string([?a..?z], min: 1),
        whitespace()
      ])
    )
    |> ignore(string("--->"))
    |> reduce({Enum, :join, []})
    |> unwrap_and_tag(:comment)

  defcombinatorp(
    :expression,
    choice([
      string("true"),
      string("false"),
      # TODO:
      string("book in books"),
      string("1 eq 2")
    ])
    |> unwrap_and_tag(:expression)
  )

  defcombinatorp(
    :static_text,
    choice([escaped_hash(), ascii_char(not: ?<, not: ?#)])
    |> repeat(lookahead_not(string("<")) |> parsec(:static_text))
  )

  defcombinatorp(
    :static_tag,
    ascii_char([?<])
    |> lookahead_not(choice([string("cf"), string("/cf"), string("!---")]))
    |> repeat(
      utf8_char(not: ?>, not: ?#)
      |> choice([escaped_hash(), utf8_char(not: ?>), parsec(:parse)])
    )
    |> ascii_char([?>])
  )

  # TODO: lookahead_not <cf ?, does this allow < in static text?
  # TODO: use chars, then reduce to list
  # repeat(
  #   lookahead_not(string("</")) |> choice([parsec(:xml), text]))
  static =
    choice([
      parsec(:static_tag),
      parsec(:static_text)
    ])
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:static)

  defcombinatorp(
    :exml,
    choice([
      comment,
      parsec(:interpolation),
      Tag.cfif(),
      Tag.cfelseif(),
      Tag.cfelse(),
      Tag.cfloop_list(),
      Tag.cfloop_range(),
      Tag.cfloop_query()
    ])
  )

  defparsec(
    :parse,
    repeat(
      choice([
        parsec(:exml),
        # TODO: fix parsing of this:
        # string("</h2>") |> unwrap_and_tag(:static),
        static
      ])
    )
  )
end
