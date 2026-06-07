defmodule ExML.CFScript.BIF.StringFns do
  @moduledoc """
  CFML string built-in functions, ported 1:1 from Lucee 6.2.5
  (`lucee.runtime.functions.string.*` and `lucee.runtime.op.Caster`).

  Names are matched lowercase (the registry downcases before dispatch);
  positions and counts are 1-based, as in CFML.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @names ~w(
    len ucase lcase ucfirst left right mid trim ltrim rtrim
    find findnocase refind rematch reescape rereplace rereplacenocase replace
    replacenocase val valnumber reverse repeatstring
  )

  @impl true
  def names, do: @names

  ## Length / collection size

  @impl true
  def call("len", [v]) when is_list(v), do: length(v)
  def call("len", [v]) when is_map(v), do: map_size(v)
  def call("len", [v]), do: String.length(Value.to_str(v))

  ## Case conversion

  def call("ucase", [v]), do: String.upcase(Value.to_str(v))
  def call("lcase", [v]), do: String.downcase(Value.to_str(v))

  def call("ucfirst", [v]) do
    case Value.to_str(v) do
      "" -> ""
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
    end
  end

  ## left / right — Lucee Left.java / Right.java
  #
  #   count == 0                -> error
  #   abs(count) >= length(str) -> whole string
  #   count < 0                 -> length + count chars (from the relevant end)

  def call("left", [v, count]) do
    s = Value.to_str(v)
    n = trunc(Value.to_number(count))
    len = String.length(s)

    cond do
      n == 0 ->
        raise CFException,
          message: "parameter 2 of the function left can not be 0 for the string [#{s}]"

      abs(n) >= len ->
        s

      n < 0 ->
        String.slice(s, 0, len + n)

      true ->
        String.slice(s, 0, n)
    end
  end

  def call("right", [v, count]) do
    s = Value.to_str(v)
    n = trunc(Value.to_number(count))
    len = String.length(s)

    cond do
      n == 0 -> raise CFException, message: "parameter 2 of the function right can not be 0"
      abs(n) >= len -> s
      n < 0 -> String.slice(s, len - (len + n), len + n)
      true -> String.slice(s, len - n, n)
    end
  end

  ## mid — Lucee Mid.java
  #
  #   start < 1   -> error; count omitted or -1 -> to end; count < -1 -> error

  def call("mid", [v, start]), do: call("mid", [v, start, -1])

  def call("mid", [v, start, count]) do
    s = Value.to_str(v)
    len = String.length(s)
    start_idx = trunc(Value.to_number(start)) - 1
    c = trunc(Value.to_number(count))

    cond do
      start_idx < 0 ->
        raise CFException,
          message:
            "Parameter 2 of function mid which is now [#{start_idx + 1}] must be a positive integer"

      c < -1 ->
        raise CFException,
          message:
            "Parameter 3 of function mid which is now [#{c}] must be a non-negative integer or -1 (for string length)"

      start_idx > len ->
        ""

      true ->
        count = if c == -1, do: len, else: c
        take = min(count, len - start_idx)
        String.slice(s, start_idx, take)
    end
  end

  ## Trimming

  def call("trim", [v]), do: String.trim(Value.to_str(v))
  def call("ltrim", [v]), do: String.trim_leading(Value.to_str(v))
  def call("rtrim", [v]), do: String.trim_trailing(Value.to_str(v))

  ## Searching

  def call("find", [needle, haystack]),
    do: find_position(Value.to_str(haystack), Value.to_str(needle), 1)

  def call("find", [needle, haystack, start]),
    do: find_position(Value.to_str(haystack), Value.to_str(needle), trunc(Value.to_number(start)))

  def call("findnocase", [needle, haystack]),
    do: find_position(downcase(haystack), downcase(needle), 1)

  def call("findnocase", [needle, haystack, start]),
    do: find_position(downcase(haystack), downcase(needle), trunc(Value.to_number(start)))

  # REFind: 1-based position of the first regex match, or 0. The
  # struct-returning (returnsubexpressions=true) form is added when a spec needs it.
  def call("refind", [pattern, string]),
    do: regex_position(Value.to_str(pattern), Value.to_str(string))

  def call("refind", [pattern, string, _start | _]),
    do: regex_position(Value.to_str(pattern), Value.to_str(string))

  def call("reescape", [v]), do: Regex.escape(Value.to_str(v))

  # reMatch: all (non-overlapping) regex matches as an array of strings.
  def call("rematch", [pattern, string]) do
    case Regex.compile(Value.to_str(pattern)) do
      {:ok, regex} -> Regex.scan(regex, Value.to_str(string)) |> Enum.map(&hd/1)
      {:error, _} -> []
    end
  end

  ## Replacement
  #
  # reReplace uses a regex; replace is literal. Default scope is "one" (first
  # match); "all" replaces every match. Replacement backreferences (`\1`) work
  # since CFML and Elixir use the same `\N` syntax.

  def call("rereplace", [s, pattern, replacement]),
    do: re_replace(s, pattern, replacement, "one", "")

  def call("rereplace", [s, pattern, replacement, scope]),
    do: re_replace(s, pattern, replacement, Value.to_str(scope), "")

  def call("rereplacenocase", [s, pattern, replacement]),
    do: re_replace(s, pattern, replacement, "one", "i")

  def call("rereplacenocase", [s, pattern, replacement, scope]),
    do: re_replace(s, pattern, replacement, Value.to_str(scope), "i")

  def call("replace", [s, from, to]), do: literal_replace(s, from, to, "one")
  def call("replace", [s, from, to, scope]), do: literal_replace(s, from, to, Value.to_str(scope))

  def call("replacenocase", [s, from, to]), do: literal_replace_nocase(s, from, to, "one")

  def call("replacenocase", [s, from, to, scope]),
    do: literal_replace_nocase(s, from, to, Value.to_str(scope))

  ## Misc

  def call("reverse", [v]), do: String.reverse(Value.to_str(v))

  def call("repeatstring", [v, count]),
    do: String.duplicate(Value.to_str(v), max(trunc(Value.to_number(count)), 0))

  # val / valNumber — Lucee Val.java / ValNumber.java: leading numeric prefix
  # (sign and a single dot allowed) -> number, else 0.
  def call(name, [v]) when name in ["val", "valnumber"] do
    s = String.trim(Value.to_str(v))
    pos = leading_number_length(s)

    if pos <= 0 do
      0
    else
      {:ok, n} = Value.as_number(binary_part(s, 0, pos))
      n
    end
  end

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  ## Helpers

  @spec downcase(any()) :: String.t()
  defp downcase(v), do: String.downcase(Value.to_str(v))

  @spec re_replace(any(), any(), any(), String.t(), String.t()) :: String.t()
  defp re_replace(s, pattern, replacement, scope, flags) do
    string = Value.to_str(s)

    case Regex.compile(Value.to_str(pattern), flags) do
      {:ok, regex} -> Regex.replace(regex, string, Value.to_str(replacement), global: all?(scope))
      {:error, _} -> string
    end
  end

  @spec literal_replace(any(), any(), any(), String.t()) :: String.t()
  defp literal_replace(s, from, to, scope) do
    String.replace(Value.to_str(s), Value.to_str(from), Value.to_str(to), global: all?(scope))
  end

  @spec literal_replace_nocase(any(), any(), any(), String.t()) :: String.t()
  defp literal_replace_nocase(s, from, to, scope) do
    pattern = Regex.compile!(Regex.escape(Value.to_str(from)), "i")

    Regex.replace(pattern, Value.to_str(s), Value.to_str(to) |> escape_replacement(),
      global: all?(scope)
    )
  end

  # `replaceNoCase` is literal, so a `\` or group-looking sequence in the
  # replacement must not be treated as a backreference.
  @spec escape_replacement(String.t()) :: String.t()
  defp escape_replacement(replacement), do: String.replace(replacement, "\\", "\\\\")

  @spec all?(String.t()) :: boolean()
  defp all?(scope), do: String.downcase(scope) == "all"

  @spec find_position(String.t(), String.t(), integer()) :: non_neg_integer()
  defp find_position(_haystack, "", _start), do: 0

  defp find_position(haystack, needle, start) do
    offset = max(start - 1, 0)
    rest = String.slice(haystack, offset, String.length(haystack))

    case :binary.match(rest, needle) do
      {pos, _len} -> offset + byte_offset_to_char(rest, pos) + 1
      :nomatch -> 0
    end
  end

  @spec byte_offset_to_char(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_to_char(string, byte_pos),
    do: string |> binary_part(0, byte_pos) |> String.length()

  @spec regex_position(String.t(), String.t()) :: non_neg_integer()
  defp regex_position(pattern, string) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} ->
        case Regex.run(regex, string, return: :index) do
          [{start, _len} | _] -> byte_offset_to_char(string, start) + 1
          nil -> 0
        end

      {:error, _} ->
        0
    end
  end

  # Port of Lucee ValNumber.getPos/1: the length of the leading numeric prefix.
  # Optional leading sign; digits; a single dot, but not a trailing dot.
  @spec leading_number_length(String.t()) :: non_neg_integer()
  defp leading_number_length(""), do: 0

  defp leading_number_length(str) do
    chars = String.graphemes(str)
    len = length(chars)
    {start, ok} = leading_sign(chars, len)

    if ok and first_is_numeric_start?(Enum.at(chars, start)) do
      scan_number(chars, start, len, false)
    else
      0
    end
  end

  @spec leading_sign([String.t()], non_neg_integer()) :: {non_neg_integer(), boolean()}
  defp leading_sign([c | _], len) when c in ["+", "-"], do: {1, len > 1}
  defp leading_sign(_chars, _len), do: {0, true}

  @spec first_is_numeric_start?(String.t() | nil) :: boolean()
  defp first_is_numeric_start?(nil), do: false
  defp first_is_numeric_start?(c), do: c == "." or (c >= "0" and c <= "9")

  @spec scan_number([String.t()], non_neg_integer(), non_neg_integer(), boolean()) ::
          non_neg_integer()
  defp scan_number(_chars, pos, len, _has_dot) when pos >= len, do: pos

  defp scan_number(chars, pos, len, has_dot) do
    case Enum.at(chars, pos) do
      "." ->
        # a trailing dot (or a second dot) terminates the number before it
        if pos + 1 >= len or has_dot, do: pos, else: scan_number(chars, pos + 1, len, true)

      c when c >= "0" and c <= "9" ->
        scan_number(chars, pos + 1, len, has_dot)

      _ ->
        pos
    end
  end
end
