defmodule ExML.CFScript.BIF.DateFns do
  @moduledoc """
  CFML date/time built-in functions, ported from Lucee 6.2.5
  (`functions/dateTime/*` and `functions/displayFormatting/*`). Date logic lives
  in `ExML.CFScript.CFDate`; dates are `NaiveDateTime`.

  Functions that take a "date" accept a date value or a parseable date string.
  `dateConvert` is a pass-through — the interpreter is timezone-naive (see
  `ExML.CFScript.CFDate`).
  """

  @behaviour ExML.CFScript.BIF

  alias ExML.CFScript.{CFDate, CFException, Value}

  @names ~w(
    now createdate createtime createdatetime createtimespan
    year month day hour minute second quarter week dayofyear daysinmonth dayofweek
    dateadd datediff datepart datecompare dateformat timeformat datetimeformat
    parsedatetime dateconvert
  )

  @impl true
  def names, do: @names

  ## Construction

  @impl true
  def call("now", _args), do: CFDate.now()
  def call("createdate", [y, m, d]), do: CFDate.create_date(int(y), int(m), int(d))
  def call("createtime", [h, mi, s]), do: CFDate.create_time(int(h), int(mi), int(s))

  def call("createdatetime", [y, m, d, h, mi, s]),
    do: CFDate.create_datetime(int(y), int(m), int(d), int(h), int(mi), int(s))

  # createTimeSpan(days, hours, minutes, seconds) -> fractional days.
  def call("createtimespan", [d, h, mi, s]),
    do: int(d) + int(h) / 24 + int(mi) / 1440 + int(s) / 86_400

  ## Field access

  def call("year", [v]), do: CFDate.year(date(v))
  def call("month", [v]), do: CFDate.month(date(v))
  def call("day", [v]), do: CFDate.day(date(v))
  def call("hour", [v]), do: CFDate.hour(date(v))
  def call("minute", [v]), do: CFDate.minute(date(v))
  def call("second", [v]), do: CFDate.second(date(v))
  def call("quarter", [v]), do: CFDate.quarter(date(v))
  def call("week", [v]), do: CFDate.week(date(v))
  def call("dayofyear", [v]), do: CFDate.day_of_year(date(v))
  def call("daysinmonth", [v]), do: CFDate.days_in_month(date(v))
  def call("dayofweek", [v]), do: CFDate.day_of_week(date(v))

  ## Arithmetic / comparison

  def call("dateadd", [part, n, v]), do: CFDate.add(Value.to_str(part), int(n), date(v))
  def call("datediff", [part, a, b]), do: CFDate.diff(Value.to_str(part), date(a), date(b))
  def call("datepart", [part, v]), do: CFDate.part(Value.to_str(part), date(v))
  def call("datecompare", [a, b]), do: CFDate.compare(date(a), date(b))
  def call("datecompare", [a, b, _precision]), do: CFDate.compare(date(a), date(b))

  ## Formatting

  def call("dateformat", [v]), do: CFDate.format(date(v), "dd-mmm-yy", false)
  def call("dateformat", [v, mask]), do: CFDate.format(date(v), date_mask(mask), false)

  def call("timeformat", [v]), do: CFDate.format(date(v), "hh:mm tt", true)
  def call("timeformat", [v, mask]), do: CFDate.format(date(v), time_mask(mask), true)

  def call("datetimeformat", [v]), do: CFDate.format(date(v), "dd-mmm-yyyy HH:nn:ss", false)
  def call("datetimeformat", [v, mask]), do: CFDate.format(date(v), date_mask(mask), false)

  ## Parsing

  def call("parsedatetime", [v | _mask]), do: date(v)

  # Pass-through: the interpreter is timezone-naive (see CFDate moduledoc).
  def call("dateconvert", [_type, v]), do: date(v)

  def call(name, args) do
    raise CFException, message: "#{name}() not supported for #{length(args)} argument(s)"
  end

  ## Helpers

  @spec int(any()) :: integer()
  defp int(v), do: trunc(Value.to_number(v))

  # Coerce an argument to a date: pass dates through, parse date strings.
  @spec date(any()) :: CFDate.t()
  defp date(%NaiveDateTime{} = ndt), do: ndt
  defp date(%Date{} = d), do: NaiveDateTime.new!(d, ~T[00:00:00])

  defp date(value) when is_binary(value) do
    case CFDate.parse(value) do
      {:ok, ndt} -> ndt
      :error -> raise CFException, message: "Can't cast [#{value}] to a date"
    end
  end

  defp date(value),
    do: raise(CFException, message: "Can't cast [#{Value.to_str(value)}] to a date")

  # Named date masks -> explicit (US-locale approximations).
  @spec date_mask(any()) :: String.t()
  defp date_mask(mask) do
    case String.downcase(Value.to_str(mask)) do
      "short" -> "m/d/yy"
      "medium" -> "mmm d, yyyy"
      "long" -> "mmmm d, yyyy"
      "full" -> "dddd, mmmm d, yyyy"
      _ -> Value.to_str(mask)
    end
  end

  @spec time_mask(any()) :: String.t()
  defp time_mask(mask) do
    case String.downcase(Value.to_str(mask)) do
      "short" -> "h:mm tt"
      m when m in ["medium", "long", "full"] -> "h:mm:ss tt"
      _ -> Value.to_str(mask)
    end
  end
end
