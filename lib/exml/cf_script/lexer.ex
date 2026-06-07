defmodule ExML.CFScript.Lexer do
  @moduledoc """
  Hand-written tokenizer for cfscript.

  Turns a cfscript source string into a flat list of tokens that
  `ExML.CFScript.Parser` consumes. Tokens are one of:

    * `{:int, integer}`
    * `{:float, float}`
    * `{:string, binary}` — quote style normalized away; doubled quotes unescaped
    * `{:ident, binary}` — identifiers and keywords alike (parser decides)
    * `{:op, binary}` — operators and punctuation (`==`, `&`, `::`, `(`, `{`, ...)

  Comments (`// ...`, `/* ... */`) and whitespace are dropped. Word operators
  like `and`/`or`/`not`/`eq` stay `:ident` tokens; the parser treats them as
  operators case-insensitively.
  """

  @type token ::
          {:int, integer()}
          | {:float, float()}
          | {:string, binary()}
          | {:ident, binary()}
          | {:op, binary()}

  # Multi-character operators, longest first so we match greedily.
  @multi_ops [
    "==",
    "!=",
    "<=",
    ">=",
    "&&",
    "||",
    "::",
    "=>",
    "<>",
    "++",
    "--",
    "+=",
    "-=",
    "&=",
    "*=",
    "/="
  ]

  @single_ops [
    "&",
    "=",
    "+",
    "-",
    "*",
    "/",
    "%",
    "^",
    "<",
    ">",
    "!",
    ".",
    ",",
    ";",
    ":",
    "(",
    ")",
    "{",
    "}",
    "[",
    "]",
    "?",
    "@"
  ]

  @doc "Tokenize `source` into a list of tokens. Raises on unterminated strings."
  @spec tokenize(binary()) :: [token()]
  def tokenize(source) when is_binary(source) do
    source
    |> do_tokenize([])
    |> Enum.reverse()
  end

  @spec do_tokenize(binary(), [token()]) :: [token()]
  defp do_tokenize("", acc), do: acc

  # Whitespace
  defp do_tokenize(<<c::utf8, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r] do
    do_tokenize(rest, acc)
  end

  # Line comment
  defp do_tokenize(<<"//", rest::binary>>, acc) do
    rest |> skip_line() |> do_tokenize(acc)
  end

  # Block comment
  defp do_tokenize(<<"/*", rest::binary>>, acc) do
    rest |> skip_block_comment() |> do_tokenize(acc)
  end

  # Strings (double or single quoted)
  defp do_tokenize(<<?", rest::binary>>, acc) do
    {value, rest} = read_string(rest, ?", "")
    do_tokenize(rest, [{:string, value} | acc])
  end

  defp do_tokenize(<<?', rest::binary>>, acc) do
    {value, rest} = read_string(rest, ?', "")
    do_tokenize(rest, [{:string, value} | acc])
  end

  # Numbers
  defp do_tokenize(<<c::utf8, _::binary>> = bin, acc) when c in ?0..?9 do
    {token, rest} = read_number(bin)
    do_tokenize(rest, [token | acc])
  end

  # Identifiers (letter or underscore start)
  defp do_tokenize(<<c::utf8, _::binary>> = bin, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {name, rest} = read_ident(bin, "")
    do_tokenize(rest, [{:ident, name} | acc])
  end

  # Operators / punctuation
  defp do_tokenize(bin, acc) do
    case match_op(bin) do
      {op, rest} ->
        do_tokenize(rest, [{:op, op} | acc])

      :error ->
        raise "ExML.CFScript.Lexer: unexpected character at #{inspect(String.slice(bin, 0, 20))}"
    end
  end

  ## Helpers

  @spec skip_line(binary()) :: binary()
  defp skip_line(<<?\n, rest::binary>>), do: rest
  defp skip_line(<<_::utf8, rest::binary>>), do: skip_line(rest)
  defp skip_line(""), do: ""

  @spec skip_block_comment(binary()) :: binary()
  defp skip_block_comment(<<"*/", rest::binary>>), do: rest
  defp skip_block_comment(<<_::utf8, rest::binary>>), do: skip_block_comment(rest)
  defp skip_block_comment(""), do: ""

  # Read a string body until the matching closing quote. A doubled quote
  # (`""` / `''`) is an escaped literal quote. The body is interpolation-aware:
  # a `#` toggles in/out of a `#...#` region, and inside such a region the quote
  # char does NOT terminate the string (so nested quotes like
  # `"#fn(x, "y")#"` work). The `#` characters are kept in the content for the
  # parser to split on.
  @spec read_string(binary(), char(), binary()) :: {binary(), binary()}
  defp read_string(bin, q, acc), do: read_string(bin, q, acc, false)

  @spec read_string(binary(), char(), binary(), boolean()) :: {binary(), binary()}
  defp read_string(<<q::utf8, q::utf8, rest::binary>>, q, acc, false) do
    read_string(rest, q, <<acc::binary, q::utf8>>, false)
  end

  defp read_string(<<?#, rest::binary>>, q, acc, in_interp) do
    read_string(rest, q, <<acc::binary, ?#>>, not in_interp)
  end

  defp read_string(<<q::utf8, rest::binary>>, q, acc, false), do: {acc, rest}

  defp read_string(<<c::utf8, rest::binary>>, q, acc, in_interp) do
    read_string(rest, q, <<acc::binary, c::utf8>>, in_interp)
  end

  defp read_string("", _q, _acc, _in_interp),
    do: raise("ExML.CFScript.Lexer: unterminated string")

  @spec read_number(binary()) :: {token(), binary()}
  defp read_number(bin) do
    {int_part, rest} = read_digits(bin, "")

    case rest do
      <<?., d::utf8, _::binary>> when d in ?0..?9 ->
        {frac, rest2} = read_digits(binary_part(rest, 1, byte_size(rest) - 1), "")
        {{:float, String.to_float(int_part <> "." <> frac)}, rest2}

      _ ->
        {{:int, String.to_integer(int_part)}, rest}
    end
  end

  @spec read_digits(binary(), binary()) :: {binary(), binary()}
  defp read_digits(<<c::utf8, rest::binary>>, acc) when c in ?0..?9 do
    read_digits(rest, <<acc::binary, c::utf8>>)
  end

  defp read_digits(bin, acc), do: {acc, bin}

  @spec read_ident(binary(), binary()) :: {binary(), binary()}
  defp read_ident(<<c::utf8, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ do
    read_ident(rest, <<acc::binary, c::utf8>>)
  end

  defp read_ident(bin, acc), do: {acc, bin}

  @spec match_op(binary()) :: {binary(), binary()} | :error
  defp match_op(bin) do
    multi =
      Enum.find(@multi_ops, fn op ->
        String.starts_with?(bin, op)
      end)

    cond do
      multi ->
        {multi, binary_part(bin, byte_size(multi), byte_size(bin) - byte_size(multi))}

      single = first_char_op(bin) ->
        {single, binary_part(bin, 1, byte_size(bin) - 1)}

      true ->
        :error
    end
  end

  @spec first_char_op(binary()) :: binary() | nil
  defp first_char_op(<<c::utf8, _::binary>>) do
    s = <<c::utf8>>
    if s in @single_ops, do: s, else: nil
  end

  defp first_char_op(""), do: nil
end
