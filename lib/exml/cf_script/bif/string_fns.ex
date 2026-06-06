defmodule ExML.CFScript.BIF.StringFns do
  @moduledoc """
  CFML string built-in functions, matching Lucee 6.2 semantics.

  All names are matched lowercase (the registry downcases before dispatch).
  Counts/positions are 1-based, as in CFML.
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFException, Value}

  @names ~w(
    len ucase lcase ucfirst left right mid trim ltrim rtrim
    find findnocase refind reescape val reverse repeatstring
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

  ## Substring helpers (1-based; Lucee clamps and supports negative count)

  def call("left", [v, count]), do: substring_left(Value.to_str(v), Value.to_number(count))
  def call("right", [v, count]), do: substring_right(Value.to_str(v), Value.to_number(count))

  def call("mid", [v, start, count]) do
    s = Value.to_str(v)
    start_idx = max(trunc(Value.to_number(start)) - 1, 0)
    String.slice(s, start_idx, max(trunc(Value.to_number(count)), 0))
  end

  def call("mid", [v, start]) do
    s = Value.to_str(v)
    start_idx = max(trunc(Value.to_number(start)) - 1, 0)
    String.slice(s, start_idx, String.length(s))
  end

  ## Trimming

  def call("trim", [v]), do: String.trim(Value.to_str(v))
  def call("ltrim", [v]), do: String.trim_leading(Value.to_str(v))
  def call("rtrim", [v]), do: String.trim_trailing(Value.to_str(v))

  ## Searching

  def call("find", [needle, haystack]) do
    find_position(Value.to_str(haystack), Value.to_str(needle), 1)
  end

  def call("find", [needle, haystack, start]) do
    find_position(Value.to_str(haystack), Value.to_str(needle), trunc(Value.to_number(start)))
  end

  def call("findnocase", [needle, haystack]) do
    find_position(downcase(haystack), downcase(needle), 1)
  end

  def call("findnocase", [needle, haystack, start]) do
    find_position(downcase(haystack), downcase(needle), trunc(Value.to_number(start)))
  end

  # REFind: 1-based position of the first regex match, or 0. The
  # struct-returning (returnsubexpressions=true) form is added when a spec needs it.
  def call("refind", [pattern, string]), do: regex_position(Value.to_str(pattern), Value.to_str(string))
  def call("refind", [pattern, string, _start | _]), do: regex_position(Value.to_str(pattern), Value.to_str(string))

  def call("reescape", [v]), do: Regex.escape(Value.to_str(v))

  ## Misc

  def call("reverse", [v]), do: String.reverse(Value.to_str(v))

  def call("repeatstring", [v, count]) do
    String.duplicate(Value.to_str(v), max(trunc(Value.to_number(count)), 0))
  end

  # `val`: leading numeric chars (a period included) -> number; 0 otherwise.
  def call("val", [v]) do
    case Value.as_number(leading_number(Value.to_str(v))) do
      {:ok, n} -> n
      :error -> 0
    end
  end

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  ## Helpers

  @spec downcase(any()) :: String.t()
  defp downcase(v), do: String.downcase(Value.to_str(v))

  # left/right with Lucee semantics: count > length returns the whole string;
  # a negative count means "all but the last |count|" (left) / "all but the
  # first |count|" (right).
  @spec substring_left(String.t(), number()) :: String.t()
  defp substring_left(s, count) do
    n = effective_count(count, String.length(s))
    String.slice(s, 0, n)
  end

  @spec substring_right(String.t(), number()) :: String.t()
  defp substring_right(s, count) do
    len = String.length(s)
    n = effective_count(count, len)
    String.slice(s, len - n, n)
  end

  @spec effective_count(number(), non_neg_integer()) :: non_neg_integer()
  defp effective_count(count, len) do
    count = trunc(count)
    resolved = if count < 0, do: len + count, else: count
    resolved |> max(0) |> min(len)
  end

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
  defp byte_offset_to_char(string, byte_pos), do: string |> binary_part(0, byte_pos) |> String.length()

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

  @spec leading_number(String.t()) :: String.t()
  defp leading_number(s) do
    case Regex.run(~r/^\s*(-?\d+(\.\d+)?)/, s) do
      [_, num | _] -> num
      nil -> "0"
    end
  end
end
