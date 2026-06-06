defmodule ExML.CFScript.Builtins do
  @moduledoc """
  Elixir implementations of CFML built-in functions (BIFs).

  Function names are matched case-insensitively, as in CFML. This is the
  starting subset needed by the first specs; more BIFs get added as specs
  demand them. An unknown name raises so gaps surface loudly rather than
  silently returning nil.
  """

  alias ExML.CFScript.{CFException, Value}

  @names ~w(
    len ucase lcase ucfirst left right mid trim
    structkeyexists isnull issimplevalue isnumeric isboolean isarray isstruct
    findnocase find refind reescape val
  )

  @doc "Whether `name` is a known built-in (case-insensitive)."
  @spec builtin?(String.t()) :: boolean()
  def builtin?(name), do: String.downcase(name) in @names

  @doc "Call a built-in by name with a list of evaluated argument values."
  @spec call(String.t(), [any()]) :: any()
  def call(name, args), do: dispatch(String.downcase(name), args)

  ## String length / collection size

  defp dispatch("len", [v]) when is_list(v), do: length(v)
  defp dispatch("len", [v]) when is_map(v), do: map_size(v)
  defp dispatch("len", [v]), do: String.length(Value.to_str(v))

  ## Case conversion

  defp dispatch("ucase", [v]), do: String.upcase(Value.to_str(v))
  defp dispatch("lcase", [v]), do: String.downcase(Value.to_str(v))

  defp dispatch("ucfirst", [v]) do
    case Value.to_str(v) do
      "" -> ""
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
    end
  end

  ## Substring helpers (1-based, CFML semantics)

  defp dispatch("left", [v, count]) do
    s = Value.to_str(v)
    n = clamp(Value.to_number(count), 0, String.length(s))
    String.slice(s, 0, n)
  end

  defp dispatch("right", [v, count]) do
    s = Value.to_str(v)
    len = String.length(s)
    n = clamp(Value.to_number(count), 0, len)
    String.slice(s, len - n, n)
  end

  defp dispatch("mid", [v, start, count]) do
    s = Value.to_str(v)
    start_idx = max(trunc(Value.to_number(start)) - 1, 0)
    String.slice(s, start_idx, trunc(Value.to_number(count)))
  end

  defp dispatch("trim", [v]), do: String.trim(Value.to_str(v))

  ## Type predicates

  defp dispatch("structkeyexists", [struct, key]) when is_map(struct) do
    Map.has_key?(struct, String.downcase(Value.to_str(key)))
  end

  defp dispatch("structkeyexists", [_other, _key]), do: false

  defp dispatch("isnull", [v]), do: is_nil(v)
  defp dispatch("issimplevalue", [v]), do: Value.simple?(v)
  defp dispatch("isnumeric", [v]), do: Value.as_number(v) != :error
  defp dispatch("isboolean", [v]), do: is_boolean(v)
  defp dispatch("isarray", [v]), do: is_list(v)
  defp dispatch("isstruct", [v]), do: is_map(v)

  ## Searching

  defp dispatch("findnocase", [needle, haystack]) do
    find_position(String.downcase(Value.to_str(haystack)), String.downcase(Value.to_str(needle)))
  end

  defp dispatch("findnocase", [needle, haystack, start]) do
    find_position(
      String.downcase(Value.to_str(haystack)),
      String.downcase(Value.to_str(needle)),
      trunc(Value.to_number(start))
    )
  end

  defp dispatch("find", [needle, haystack]) do
    find_position(Value.to_str(haystack), Value.to_str(needle))
  end

  # Minimal REFind: returns 1-based position of the first regex match, or 0.
  # (The struct-returning `returnsubexpressions=true` form comes later.)
  defp dispatch("refind", [pattern, string]) do
    regex_position(Value.to_str(pattern), Value.to_str(string))
  end

  defp dispatch("refind", [pattern, string, _start | _]) do
    regex_position(Value.to_str(pattern), Value.to_str(string))
  end

  defp dispatch("reescape", [v]), do: Regex.escape(Value.to_str(v))

  defp dispatch("val", [v]) do
    case Value.as_number(leading_number(Value.to_str(v))) do
      {:ok, n} -> n
      :error -> 0
    end
  end

  defp dispatch(name, args) do
    raise CFException,
      message: "Built-in '#{name}' not implemented for #{length(args)} argument(s)"
  end

  ## Helpers

  @spec clamp(number(), integer(), integer()) :: integer()
  defp clamp(n, lo, hi), do: n |> trunc() |> max(lo) |> min(hi)

  @spec find_position(String.t(), String.t(), pos_integer()) :: non_neg_integer()
  defp find_position(haystack, needle, start \\ 1)
  defp find_position(_haystack, "", _start), do: 0

  defp find_position(haystack, needle, start) do
    offset = max(start - 1, 0)
    prefix = String.slice(haystack, 0, offset)
    rest = String.slice(haystack, offset, String.length(haystack))

    case :binary.match(rest, needle) do
      {pos, _len} -> String.length(prefix) + byte_offset_to_char(rest, pos) + 1
      :nomatch -> 0
    end
  end

  # :binary.match returns a byte offset; convert to a character index.
  defp byte_offset_to_char(string, byte_pos) do
    string |> binary_part(0, byte_pos) |> String.length()
  end

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
