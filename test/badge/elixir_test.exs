defmodule Badge.ElixirTest do
  use ExUnit.Case, async: true

  alias Badge.Elixir.Lexer
  alias Badge.Elixir.Parser

  # Feeds one line into a fresh session and evaluates it against bindings.
  defp run(line, bindings \\ %{}) do
    {:eval, _session, exprs} = Badge.Elixir.feed(Badge.Elixir.new(), line)
    Badge.Elixir.run(exprs, bindings)
  end

  defp value(line, bindings \\ %{}) do
    {{:ok, text}, _bindings} = run(line, bindings)
    text
  end

  defp error(line, bindings \\ %{}) do
    {{:error, text}, _bindings} = run(line, bindings)
    text
  end

  describe "Lexer.tokenize/1" do
    test "reads every token kind" do
      assert Lexer.tokenize("x = Enum.map([1, 2.5], &f/1) |> IO.inspect(label: \"n\")") ==
               {:ok,
                [
                  {:ident, :x},
                  :"=",
                  {:alias, Enum},
                  :".",
                  {:ident, :map},
                  :"(",
                  :"[",
                  {:int, 1},
                  :",",
                  {:float, 2.5},
                  :"]",
                  :",",
                  :"&",
                  {:ident, :f},
                  :"/",
                  {:int, 1},
                  :")",
                  :"|>",
                  {:alias, IO},
                  :".",
                  {:ident, :inspect},
                  :"(",
                  {:kw, :label},
                  {:string, "n"},
                  :")"
                ]}
    end

    test "atoms, keywords, literals and comments" do
      assert Lexer.tokenize(~s|:ok :"a b" fn end true nil is_nil? # note|) ==
               {:ok, [{:atom, :ok}, {:atom, :"a b"}, :fn, :end, {:atom, true}, {:atom, nil}, {:ident, :is_nil?}]}
    end

    test "newlines and semicolons separate" do
      assert Lexer.tokenize("1;2\n3") == {:ok, [{:int, 1}, :sep, {:int, 2}, :sep, {:int, 3}]}
    end

    test "string escapes" do
      assert Lexer.tokenize(~s|"a\\"b\\n"|) == {:ok, [{:string, "a\"b\n"}]}
    end

    test "an unterminated string is an error" do
      assert Lexer.tokenize(~s|"abc|) == {:error, "unterminated string"}
    end

    test "an unknown character is an error" do
      assert Lexer.tokenize("1 $ 2") == {:error, "unexpected $"}
    end
  end

  describe "Parser.parse/1" do
    defp ast(line) do
      {:ok, tokens} = Lexer.tokenize(line)
      Parser.parse(tokens)
    end

    test "precedence and associativity" do
      assert ast("1 + 2 * 3") == {:ok, [{:op, :+, {:lit, 1}, {:op, :*, {:lit, 2}, {:lit, 3}}}]}
      assert ast("a = b = 1") == {:ok, [{:match, {:var, :a}, {:match, {:var, :b}, {:lit, 1}}}]}
      assert ast("1 - 2 - 3") == {:ok, [{:op, :-, {:op, :-, {:lit, 1}, {:lit, 2}}, {:lit, 3}}]}
    end

    test "pipes insert the left side as the first argument" do
      assert ast("x |> Enum.map(f)") == {:ok, [{:call, {:lit, Enum}, :map, [{:var, :x}, {:var, :f}]}]}
      assert ast("x |> 1") == {:error, "cannot pipe into that"}
    end

    test "collections" do
      assert ast("[1 | t]") == {:ok, [{:cons, [{:lit, 1}], {:var, :t}}]}
      assert ast("{1, a: 2}") == {:ok, [{:tuple, [{:lit, 1}, {:tuple, [{:lit, :a}, {:lit, 2}]}]}]}
      assert ast(~s|%{a: 1, "b" => 2}|) == {:ok, [{:map, [{{:lit, :a}, {:lit, 1}}, {{:lit, "b"}, {:lit, 2}}]}]}
      assert ast("%{m | a: 1}") == {:ok, [{:map_update, {:var, :m}, [{{:lit, :a}, {:lit, 1}}]}]}
    end

    test "keyword arguments become a trailing list" do
      assert ast("f(1, a: 2)") ==
               {:ok, [{:local, :f, [{:lit, 1}, {:list, [{:tuple, [{:lit, :a}, {:lit, 2}]}]}]}]}
    end

    test "fn clauses end at the next head" do
      assert ast("fn 0 -> :z; n -> n end") ==
               {:ok, [{:fn, [{[{:lit, 0}], [{:lit, :z}]}, {[{:var, :n}], [{:var, :n}]}]}]}
    end

    test "unfinished input is an error" do
      assert ast("1 +") == {:error, "unexpected end"}
      assert ast("(1") == {:error, "expected )"}
      assert ast("1 2") == {:error, "unexpected 2"}
    end
  end

  describe "feed/2" do
    test "waits while brackets or blocks are open" do
      assert {:pending, session} = Badge.Elixir.feed(Badge.Elixir.new(), "fn x ->")
      assert Badge.Elixir.pending?(session)
      assert {:pending, session} = Badge.Elixir.feed(session, "x + 1")
      assert {:eval, _session, [{:fn, _clauses}]} = Badge.Elixir.feed(session, "end")
    end

    test "an empty line changes nothing" do
      {:pending, session} = Badge.Elixir.feed(Badge.Elixir.new(), "[1,")

      assert Badge.Elixir.feed(session, "") == {:pending, session}
    end

    test "a stray closer is an error and drops what was pending" do
      {:pending, session} = Badge.Elixir.feed(Badge.Elixir.new(), "[1,")

      assert {:error, reset, "unexpected end"} = Badge.Elixir.feed(session, "2]]")
      refute Badge.Elixir.pending?(reset)
    end
  end

  describe "run/2" do
    test "arithmetic, comparison and booleans" do
      assert value("1 + 2 * 3 - 4 / 2") == "5.0"
      assert value("3 > 2 && 2 >= 2") == "true"
      assert value("nil || :default") == ":default"
      assert value("!nil") == "true"
      assert value("not true") == "false"
      assert value("-3") == "-3"
      assert value("1 in [1, 2]") == "true"
    end

    test "strings, lists and maps" do
      assert value(~s|"ab" <> "cd"|) == ~s|"abcd"|
      assert value("[1, 2] ++ [3]") == "[1, 2, 3]"
      assert value("[1 | [2]]") == "[1, 2]"
      assert value("%{a: 1}.a") == "1"
      assert value("%{%{a: 1} | a: 2}") == "%{a: 2}"
      assert error("%{%{a: 1} | b: 2}") == "** (KeyError) key :b not found"
    end

    test "matching binds and destructures" do
      {{:ok, _text}, bindings} = run("{:ok, [h | t]} = {:ok, [1, 2, 3]}")

      assert bindings == %{h: 1, t: [2, 3]}
      assert value(~s|"a" <> rest = "abc"; rest|) == ~s|"bc"|
      assert value("%{a: x} = %{a: 1, b: 2}; x") == "1"
      assert value("^x = 1", %{x: 1}) == "1"
      assert error("^x = 2", %{x: 1}) == "** (MatchError) no match: 2"
    end

    test "calls" do
      assert value(":erlang.length([1])") == "1"
      assert value("Enum.map([1, 2], fn n -> n * 2 end)") == "[2, 4]"
      assert value("length([1, 2, 3])") == "3"
      assert value("elem({1, 2}, 1)") == "2"
      assert value("max(1, 2)") == "2"
      assert value("inspect(:a)") == ~s|":a"|
      assert value("to_string(1)") == ~s|"1"|
      assert value("m = :lists; m.reverse([1, 2])") == "[2, 1]"
      assert value("Enum.reduce([1, 2, 3], 0, &Kernel.+/2)") == "6"
      assert value("Enum.map([1, 2], &(&1 * 10))") == "[10, 20]"
      assert value("1 |> Kernel.+(2)") == "3"
    end

    test "functions and clauses" do
      assert value("f = fn 0 -> :zero; n -> n end; f.(0)") == ":zero"
      assert value("f = fn 0 -> :zero; n -> n end; f.(7)") == "7"
      assert value("add = fn a, b -> a + b end; add.(1, 2)") == "3"
      assert error("f = fn 0 -> :zero end; f.(1)") == "** (FunctionClauseError) no clause matching"
    end

    test "case and if keep their bindings inside" do
      assert value("case {1, 2} do {a, b} -> a + b end") == "3"
      assert error("case 3 do 1 -> :one end") == "** (CaseClauseError) no clause matching: 3"
      assert value("if 1 > 2 do :yes else :no end") == ":no"
      assert value("if 1 do :yes end") == ":yes"
      assert value("if nil do :yes end") == "nil"
      {{:ok, _text}, bindings} = run("case 1 do a -> a end")
      assert bindings == %{}
    end

    test "errors are described, not raised" do
      assert error("y") == "** (CompileError) undefined variable y"
      assert error("1 / 0") == "** (ArithmeticError) bad argument in arithmetic"
      assert error("nope(1)") == "** (UndefinedFunctionError) nope/1"
      assert error("1.(2)") == "** (BadFunctionError) not a function: 1"
      assert error("throw(:x)") == "** (throw) :x"
      assert error("raise(\"boom\")") == ~s|** (error) "boom"|
    end

    test "bindings survive an error" do
      {_result, bindings} = run("x = 1; 1 / 0")

      assert bindings == %{}
      {{:error, _text}, bindings} = run("1 / 0", %{x: 1})
      assert bindings == %{x: 1}
    end

    test "long output is clipped" do
      {{:ok, text}, _bindings} = run(":lists.seq(1, 500)")

      assert byte_size(text) == 240
      assert :binary.part(text, 237, 3) == "..."
    end
  end

  describe "worker" do
    test "answers the owner and keeps bindings between lines" do
      worker = Badge.Elixir.start(self())
      {:eval, _session, exprs} = Badge.Elixir.feed(Badge.Elixir.new(), "x = 5")
      Badge.Elixir.eval(worker, exprs)
      assert_receive {:console, ^worker, {:ok, "5"}}

      {:eval, _session, exprs} = Badge.Elixir.feed(Badge.Elixir.new(), "x * 2")
      Badge.Elixir.eval(worker, exprs)
      assert_receive {:console, ^worker, {:ok, "10"}}

      Badge.Elixir.stop(worker)
    end

    test "stop kills it" do
      worker = Badge.Elixir.start(self())
      ref = Process.monitor(worker)

      Badge.Elixir.stop(worker)

      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    end
  end
end
