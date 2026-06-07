defmodule ExML.CFScript.CFDate do
  @moduledoc """
  CFML date/time core: construction, field access, arithmetic, comparison,
  parsing, and mask formatting.

  Dates are modelled as Elixir `NaiveDateTime` (timezone-naive, matching how
  CFML treats dates in expressions). The CFML date *serial* (days since
  1899-12-30) is exposed via `serial/1` so dates compare and order numerically,
  as in Lucee.

  Timezone conversion (`dateConvert`) is a pass-through here — the interpreter
  is timezone-naive, so a host that needs UTC/local conversion must normalize
  dates itself. All other functions are timezone-independent.
  """

  alias ExML.CFScript.CFException

  @epoch ~N[1899-12-30 00:00:00]
  @months ~w(January February March April May June July August September October November December)
  @days ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  @type t :: NaiveDateTime.t()

  ## Construction

  @spec now() :: t()
  def now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  @spec create_date(integer(), integer(), integer()) :: t()
  def create_date(year, month, day), do: new(year, month, day, 0, 0, 0)

  @spec create_time(integer(), integer(), integer()) :: t()
  def create_time(hour, minute, second), do: new(1899, 12, 30, hour, minute, second)

  @spec create_datetime(integer(), integer(), integer(), integer(), integer(), integer()) :: t()
  def create_datetime(year, month, day, hour, minute, second),
    do: new(year, month, day, hour, minute, second)

  @spec new(integer(), integer(), integer(), integer(), integer(), integer()) :: t()
  def new(year, month, day, hour, minute, second) do
    case NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, ndt} -> ndt
      {:error, reason} -> raise CFException, message: "Invalid date: #{inspect(reason)}"
    end
  end

  ## Field access

  @spec year(t()) :: integer()
  def year(%NaiveDateTime{year: y}), do: y
  @spec month(t()) :: integer()
  def month(%NaiveDateTime{month: m}), do: m
  @spec day(t()) :: integer()
  def day(%NaiveDateTime{day: d}), do: d
  @spec hour(t()) :: integer()
  def hour(%NaiveDateTime{hour: h}), do: h
  @spec minute(t()) :: integer()
  def minute(%NaiveDateTime{minute: m}), do: m
  @spec second(t()) :: integer()
  def second(%NaiveDateTime{second: s}), do: s
  @spec quarter(t()) :: integer()
  def quarter(%NaiveDateTime{month: m}), do: div(m - 1, 3) + 1

  # CFML dayOfWeek: 1 = Sunday .. 7 = Saturday (Elixir is 1 = Monday .. 7 = Sunday).
  @spec day_of_week(t()) :: integer()
  def day_of_week(ndt), do: rem(Date.day_of_week(NaiveDateTime.to_date(ndt)), 7) + 1

  @spec day_of_year(t()) :: integer()
  def day_of_year(ndt), do: Date.day_of_year(NaiveDateTime.to_date(ndt))

  @spec week(t()) :: integer()
  def week(ndt), do: elem(:calendar.iso_week_number(date_tuple(ndt)), 1)

  @spec days_in_month(t()) :: integer()
  def days_in_month(ndt), do: Date.days_in_month(NaiveDateTime.to_date(ndt))

  ## Serial number (days since 1899-12-30), for numeric coercion/comparison

  @spec serial(t()) :: float()
  def serial(ndt), do: NaiveDateTime.diff(ndt, @epoch, :second) / 86_400.0

  ## Comparison

  @spec compare(t(), t()) :: integer()
  def compare(a, b) do
    case NaiveDateTime.compare(a, b) do
      :lt -> -1
      :eq -> 0
      :gt -> 1
    end
  end

  ## Arithmetic — dateAdd(datepart, n, date), Lucee datepart codes

  @spec add(String.t(), integer(), t()) :: t()
  def add(datepart, n, ndt) do
    case String.downcase(datepart) do
      "l" ->
        NaiveDateTime.add(ndt, n, :millisecond)

      "s" ->
        NaiveDateTime.add(ndt, n, :second)

      "n" ->
        NaiveDateTime.add(ndt, n * 60, :second)

      "h" ->
        NaiveDateTime.add(ndt, n * 3600, :second)

      "d" ->
        NaiveDateTime.add(ndt, n * 86_400, :second)

      "y" ->
        NaiveDateTime.add(ndt, n * 86_400, :second)

      "ww" ->
        NaiveDateTime.add(ndt, n * 7 * 86_400, :second)

      "w" ->
        NaiveDateTime.add(ndt, n * 86_400, :second)

      "m" ->
        add_months(ndt, n)

      "q" ->
        add_months(ndt, n * 3)

      "yyyy" ->
        add_months(ndt, n * 12)

      other ->
        raise CFException, message: "invalid datepart identifier [#{other}] for function dateAdd"
    end
  end

  ## Difference — dateDiff(datepart, date1, date2)

  @spec diff(String.t(), t(), t()) :: integer()
  def diff(datepart, a, b) do
    secs = NaiveDateTime.diff(b, a, :second)

    case String.downcase(datepart) do
      "s" ->
        secs

      "n" ->
        div(secs, 60)

      "h" ->
        div(secs, 3600)

      "d" ->
        div(secs, 86_400)

      "y" ->
        div(secs, 86_400)

      "ww" ->
        div(div(secs, 86_400), 7)

      "w" ->
        div(div(secs, 86_400), 7)

      "m" ->
        month_diff(a, b)

      "q" ->
        div(month_diff(a, b), 3)

      "yyyy" ->
        div(month_diff(a, b), 12)

      other ->
        raise CFException, message: "invalid datepart identifier [#{other}] for function dateDiff"
    end
  end

  ## datePart(datepart, date)

  @spec part(String.t(), t()) :: integer()
  def part(datepart, ndt) do
    case String.downcase(datepart) do
      "yyyy" ->
        year(ndt)

      "q" ->
        quarter(ndt)

      "m" ->
        month(ndt)

      "y" ->
        day_of_year(ndt)

      "d" ->
        day(ndt)

      "w" ->
        day_of_week(ndt)

      "ww" ->
        week(ndt)

      "h" ->
        hour(ndt)

      "n" ->
        minute(ndt)

      "s" ->
        second(ndt)

      other ->
        raise CFException, message: "invalid datepart identifier [#{other}] for function datePart"
    end
  end

  ## Parsing — common date string formats

  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(string) do
    string = String.trim(string)

    cond do
      m =
          Regex.run(
            ~r/^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$/,
            string
          ) ->
        from_parts(m)

      m = Regex.run(~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/, string) ->
        [_, mo, d, y] = m
        ok_new(y, mo, d, "0", "0", "0")

      m = Regex.run(~r/^(\d{4})(\d{2})(\d{2})$/, string) ->
        [_, y, mo, d] = m
        ok_new(y, mo, d, "0", "0", "0")

      true ->
        :error
    end
  end

  @spec parseable?(String.t()) :: boolean()
  def parseable?(string), do: match?({:ok, _}, parse(string))

  ## Formatting — CFML mask language
  #
  # `m_is_minute?` distinguishes timeFormat (m = minutes) from dateFormat /
  # dateTimeFormat (m = month, n = minutes).

  @spec format(t(), String.t(), boolean()) :: String.t()
  def format(ndt, mask, m_is_minute?) do
    mask
    |> tokenize_mask()
    |> Enum.map_join("", fn {char, count} -> render(char, count, ndt, m_is_minute?) end)
  end

  ## Helpers

  @spec add_months(t(), integer()) :: t()
  defp add_months(ndt, n) do
    months = year(ndt) * 12 + (month(ndt) - 1) + n
    y = div(months, 12)
    m = rem(months, 12) + 1
    d = min(day(ndt), Date.days_in_month(Date.new!(y, m, 1)))
    new(y, m, d, hour(ndt), minute(ndt), second(ndt))
  end

  @spec month_diff(t(), t()) :: integer()
  defp month_diff(a, b), do: (year(b) - year(a)) * 12 + (month(b) - month(a))

  @spec date_tuple(t()) :: {integer(), integer(), integer()}
  defp date_tuple(%NaiveDateTime{year: y, month: m, day: d}), do: {y, m, d}

  @spec from_parts([String.t()]) :: {:ok, t()}
  defp from_parts([_, y, mo, d]), do: ok_new(y, mo, d, "0", "0", "0")
  defp from_parts([_, y, mo, d, h, mi]), do: ok_new(y, mo, d, h, mi, "0")
  defp from_parts([_, y, mo, d, h, mi, s]), do: ok_new(y, mo, d, h, mi, s)

  @spec ok_new(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()}
  defp ok_new(y, mo, d, h, mi, s) do
    {:ok, new(int(y), int(mo), int(d), int(h), int(mi), int(s))}
  end

  defp int(s), do: String.to_integer(s)

  # Group the mask into runs of identical characters (case matters for H vs h).
  @spec tokenize_mask(String.t()) :: [{String.t(), pos_integer()}]
  defp tokenize_mask(mask) do
    mask
    |> String.graphemes()
    |> Enum.chunk_by(& &1)
    |> Enum.map(fn run -> {hd(run), length(run)} end)
  end

  @spec render(String.t(), pos_integer(), t(), boolean()) :: String.t()
  defp render(char, count, ndt, m_is_minute?) do
    case {downcase_unless_hour(char), count} do
      {"y", n} when n <= 2 -> ndt |> year() |> rem(100) |> pad(2)
      {"y", _} -> ndt |> year() |> pad(4)
      {"m", _} when m_is_minute? -> ndt |> minute() |> pad(min(count, 2))
      {"m", 3} -> Enum.at(@months, month(ndt) - 1) |> String.slice(0, 3)
      {"m", n} when n >= 4 -> Enum.at(@months, month(ndt) - 1)
      {"m", n} -> ndt |> month() |> pad(n)
      {"n", n} -> ndt |> minute() |> pad(min(n, 2))
      {"d", 3} -> day_name(ndt) |> String.slice(0, 3)
      {"d", n} when n >= 4 -> day_name(ndt)
      {"d", n} -> ndt |> day() |> pad(n)
      {"H", n} -> ndt |> hour() |> pad(min(n, 2))
      {"h", n} -> ndt |> hour() |> hour12() |> pad(min(n, 2))
      {"s", n} -> ndt |> second() |> pad(min(n, 2))
      {"t", 1} -> if hour(ndt) < 12, do: "A", else: "P"
      {"t", _} -> if hour(ndt) < 12, do: "AM", else: "PM"
      {literal, n} -> String.duplicate(literal, n)
    end
  end

  # Hour token is case-significant (H = 24h, h = 12h); everything else folds.
  defp downcase_unless_hour("H"), do: "H"
  defp downcase_unless_hour(c), do: String.downcase(c)

  defp hour12(h) do
    case rem(h, 12) do
      0 -> 12
      h12 -> h12
    end
  end

  defp day_name(ndt), do: Enum.at(@days, day_of_week(ndt) - 1)
  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
