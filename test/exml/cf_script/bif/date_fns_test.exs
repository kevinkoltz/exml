defmodule ExML.CFScript.BIF.DateFnsTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.BIF.Registry, as: R

  # Behavior verified against Lucee 6.2.5 (functions/dateTime + displayFormatting).
  # 2023-09-03 is a Sunday.

  defp d, do: R.call("createDateTime", [2023, 9, 3, 14, 30, 25])

  test "createDate / createDateTime + field access" do
    assert R.call("year", [d()]) == 2023
    assert R.call("month", [d()]) == 9
    assert R.call("day", [d()]) == 3
    assert R.call("hour", [d()]) == 14
    assert R.call("minute", [d()]) == 30
    assert R.call("second", [d()]) == 25
    assert R.call("quarter", [d()]) == 3
  end

  test "dayOfWeek is 1=Sunday..7=Saturday" do
    assert R.call("dayOfWeek", [R.call("createDate", [2023, 9, 3])]) == 1
    assert R.call("dayOfWeek", [R.call("createDate", [2023, 9, 4])]) == 2
  end

  describe "dateFormat masks" do
    test "numeric masks" do
      assert R.call("dateFormat", [d(), "yyyy-mm-dd"]) == "2023-09-03"
      assert R.call("dateFormat", [d(), "mm/dd/yyyy"]) == "09/03/2023"
      assert R.call("dateFormat", [d(), "m/d/yy"]) == "9/3/23"
      assert R.call("dateFormat", [d(), "yyyymmdd"]) == "20230903"
    end

    test "name masks" do
      assert R.call("dateFormat", [d(), "mmm"]) == "Sep"
      assert R.call("dateFormat", [d(), "mmmm"]) == "September"
      assert R.call("dateFormat", [d(), "ddd"]) == "Sun"
      assert R.call("dateFormat", [d(), "dddd"]) == "Sunday"
    end
  end

  describe "timeFormat masks (m = minutes)" do
    test "24h and 12h" do
      assert R.call("timeFormat", [d(), "HH:mm:ss"]) == "14:30:25"
      assert R.call("timeFormat", [d(), "h:mm tt"]) == "2:30 PM"
      assert R.call("timeFormat", [R.call("createTime", [9, 5, 0]), "hh:mm tt"]) == "09:05 AM"
    end
  end

  describe "dateAdd" do
    test "day / month / year / week / hour" do
      base = R.call("createDate", [2023, 9, 3])

      assert R.call("dateFormat", [R.call("dateAdd", ["d", 1, base]), "yyyy-mm-dd"]) ==
               "2023-09-04"

      assert R.call("dateFormat", [R.call("dateAdd", ["m", 1, base]), "yyyy-mm-dd"]) ==
               "2023-10-03"

      assert R.call("dateFormat", [R.call("dateAdd", ["yyyy", 1, base]), "yyyy-mm-dd"]) ==
               "2024-09-03"

      assert R.call("dateFormat", [R.call("dateAdd", ["ww", 1, base]), "yyyy-mm-dd"]) ==
               "2023-09-10"

      assert R.call("timeFormat", [R.call("dateAdd", ["h", 2, d()]), "HH:mm"]) == "16:30"
    end

    test "month add clamps the day (Jan 31 + 1 month)" do
      jan31 = R.call("createDate", [2024, 1, 31])

      assert R.call("dateFormat", [R.call("dateAdd", ["m", 1, jan31]), "yyyy-mm-dd"]) ==
               "2024-02-29"
    end
  end

  test "dateDiff" do
    a = R.call("createDate", [2023, 9, 3])
    b = R.call("createDate", [2023, 9, 10])
    assert R.call("dateDiff", ["d", a, b]) == 7
    assert R.call("dateDiff", ["ww", a, b]) == 1
    assert R.call("dateDiff", ["m", a, R.call("createDate", [2023, 12, 3])]) == 3
    assert R.call("dateDiff", ["yyyy", a, R.call("createDate", [2025, 9, 3])]) == 2
  end

  test "datePart / dateCompare" do
    assert R.call("datePart", ["yyyy", d()]) == 2023
    assert R.call("datePart", ["n", d()]) == 30
    a = R.call("createDate", [2023, 1, 1])
    b = R.call("createDate", [2023, 6, 1])
    assert R.call("dateCompare", [a, b]) == -1
    assert R.call("dateCompare", [b, a]) == 1
    assert R.call("dateCompare", [a, a]) == 0
  end

  test "parseDateTime + date string coercion" do
    assert R.call("year", ["2023-09-03"]) == 2023
    assert R.call("dateFormat", ["09/03/2023", "yyyy-mm-dd"]) == "2023-09-03"
    assert R.call("dateFormat", ["20230903", "yyyy-mm-dd"]) == "2023-09-03"
    assert R.call("year", [R.call("parseDateTime", ["2023-09-03 14:30:25"])]) == 2023
  end

  test "createTimeSpan is fractional days" do
    assert R.call("createTimeSpan", [0, 12, 0, 0]) == 0.5
    assert R.call("createTimeSpan", [1, 0, 0, 0]) == 1
  end

  test "isDate" do
    assert R.call("isDate", [d()])
    assert R.call("isDate", ["2023-09-03"])
    refute R.call("isDate", ["hello"])
    refute R.call("isDate", [5])
  end
end
