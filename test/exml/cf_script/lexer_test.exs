defmodule ExML.CFScript.LexerTest do
  use ExUnit.Case, async: true

  alias ExML.CFScript.Lexer

  test "tokenizes identifiers, numbers, strings" do
    assert Lexer.tokenize(~s|foo 42 3.5 "bar"|) == [
             {:ident, "foo"},
             {:int, 42},
             {:float, 3.5},
             {:string, "bar"}
           ]
  end

  test "doubled quotes escape inside strings" do
    assert Lexer.tokenize(~s|"he said ""hi"""|) == [{:string, ~s|he said "hi"|}]
    assert Lexer.tokenize(~s|''|) == [{:string, ""}]
  end

  test "multi-char and single-char operators" do
    assert Lexer.tokenize("a == b & c :: d") == [
             {:ident, "a"},
             {:op, "=="},
             {:ident, "b"},
             {:op, "&"},
             {:ident, "c"},
             {:op, "::"},
             {:ident, "d"}
           ]
  end

  test "skips line and block comments" do
    src = """
    a // trailing
    /* block
       comment */ b
    """

    assert Lexer.tokenize(src) == [{:ident, "a"}, {:ident, "b"}]
  end

  test "tokenizes the capitalize function body" do
    src = ~s|return ucase(left(str, 1)) & right(str, len(str)-1);|

    assert Lexer.tokenize(src) == [
             {:ident, "return"},
             {:ident, "ucase"},
             {:op, "("},
             {:ident, "left"},
             {:op, "("},
             {:ident, "str"},
             {:op, ","},
             {:int, 1},
             {:op, ")"},
             {:op, ")"},
             {:op, "&"},
             {:ident, "right"},
             {:op, "("},
             {:ident, "str"},
             {:op, ","},
             {:ident, "len"},
             {:op, "("},
             {:ident, "str"},
             {:op, ")"},
             {:op, "-"},
             {:int, 1},
             {:op, ")"},
             {:op, ";"}
           ]
  end
end
