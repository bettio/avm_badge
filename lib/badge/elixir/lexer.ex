defmodule Badge.Elixir.Lexer do
  @moduledoc """
  Tokens for the Elixir subset the prompt reads.

  Values are tagged tuples: `{:int, 1}`, `{:float, 1.5}`, `{:atom, :a}`,
  `{:string, "s"}`, `{:ident, :name}`, `{:alias, Mod}` and `{:kw, :key}`
  for a `key:` inside a list, map or call. Everything else is a bare atom
  such as `:"("`, `:"|>"`, `:fn` or `:end`; a newline or `;` is `:sep`.
  """

  @keywords %{
    ~c"fn" => :fn,
    ~c"end" => :end,
    ~c"do" => :do,
    ~c"else" => :else,
    ~c"case" => :case,
    ~c"if" => :if,
    ~c"not" => :not,
    ~c"and" => :and,
    ~c"or" => :or,
    ~c"in" => :in,
    ~c"when" => :when
  }

  @literals %{~c"true" => true, ~c"false" => false, ~c"nil" => nil}

  @two [~c"|>", ~c"==", ~c"!=", ~c"<=", ~c">=", ~c"++", ~c"--", ~c"<>", ~c"->", ~c"=>", ~c"&&", ~c"||", ~c"%{"]
  @one ~c"+-*/=<>!|&.,()[]{}^"

  defguardp is_digit(c) when c >= ?0 and c <= ?9
  defguardp is_lower(c) when (c >= ?a and c <= ?z) or c == ?_
  defguardp is_upper(c) when c >= ?A and c <= ?Z
  defguardp is_word(c) when is_digit(c) or is_lower(c) or is_upper(c)

  @doc "Splits a line or several into tokens."
  @spec tokenize(binary) :: {:ok, [term]} | {:error, binary}
  def tokenize(text) do
    try do
      {:ok, lex(:erlang.binary_to_list(text), [])}
    catch
      {:lex, reason} -> {:error, reason}
    end
  end

  defp lex([], acc), do: :lists.reverse(acc)
  defp lex([c | rest], acc) when c == ?\s or c == ?\t or c == ?\r, do: lex(rest, acc)
  defp lex([?\n | rest], acc), do: lex(rest, [:sep | acc])
  defp lex([?; | rest], acc), do: lex(rest, [:sep | acc])
  defp lex([?# | rest], acc), do: lex(drop_line(rest), acc)
  defp lex([?" | rest], acc), do: string(rest, [], acc)
  defp lex([?:, ?" | rest], acc), do: quoted_atom(rest, [], acc)
  defp lex([?:, c | _] = chars, acc) when is_lower(c) or is_upper(c), do: atom(tl(chars), [], acc)
  defp lex([c | _] = chars, acc) when is_digit(c), do: number(chars, [], acc)
  defp lex([c | _] = chars, acc) when is_lower(c), do: ident(chars, [], acc)
  defp lex([c | _] = chars, acc) when is_upper(c), do: alias(chars, [], acc)
  defp lex([a, b | rest] = chars, acc), do: operator(chars, [a, b], rest, acc)
  defp lex([a | rest] = chars, acc), do: operator(chars, [a], rest, acc)

  defp operator(chars, [a, b] = two, rest, acc) do
    case :lists.member(two, @two) do
      true -> lex(rest, [:erlang.list_to_atom(two) | acc])
      false -> operator(chars, [a], [b | rest], acc)
    end
  end

  defp operator(_chars, [a], rest, acc) do
    case :lists.member(a, @one) do
      true -> lex(rest, [:erlang.list_to_atom([a]) | acc])
      false -> throw({:lex, "unexpected " <> <<a>>})
    end
  end

  defp drop_line([]), do: []
  defp drop_line([?\n | _] = rest), do: rest
  defp drop_line([_c | rest]), do: drop_line(rest)

  defp string([], _chars, _acc), do: throw({:lex, "unterminated string"})
  defp string([?" | rest], chars, acc), do: lex(rest, [{:string, text(chars)} | acc])
  defp string([?\\, ?n | rest], chars, acc), do: string(rest, [?\n | chars], acc)
  defp string([?\\, ?t | rest], chars, acc), do: string(rest, [?\t | chars], acc)
  defp string([?\\, c | rest], chars, acc), do: string(rest, [c | chars], acc)
  defp string([c | rest], chars, acc), do: string(rest, [c | chars], acc)

  defp quoted_atom([], _chars, _acc), do: throw({:lex, "unterminated atom"})
  defp quoted_atom([?" | rest], chars, acc), do: lex(rest, [{:atom, name(chars)} | acc])
  defp quoted_atom([c | rest], chars, acc), do: quoted_atom(rest, [c | chars], acc)

  defp atom([c | rest], chars, acc) when is_word(c), do: atom(rest, [c | chars], acc)
  defp atom([c | rest], chars, acc) when c == ?? or c == ?!, do: lex(rest, [{:atom, name([c | chars])} | acc])
  defp atom(rest, chars, acc), do: lex(rest, [{:atom, name(chars)} | acc])

  defp number([c | rest], digits, acc) when is_digit(c), do: number(rest, [c | digits], acc)
  defp number([?_ | rest], digits, acc), do: number(rest, digits, acc)

  defp number([?., c | rest], digits, acc) when is_digit(c) do
    fraction(rest, [c, ?. | digits], acc)
  end

  defp number(rest, digits, acc) do
    lex(rest, [{:int, :erlang.list_to_integer(:lists.reverse(digits))} | acc])
  end

  defp fraction([c | rest], digits, acc) when is_digit(c), do: fraction(rest, [c | digits], acc)

  defp fraction(rest, digits, acc) do
    lex(rest, [{:float, :erlang.list_to_float(:lists.reverse(digits))} | acc])
  end

  defp ident([c | rest], chars, acc) when is_word(c), do: ident(rest, [c | chars], acc)
  defp ident([c | rest], chars, acc) when c == ?? or c == ?!, do: word(rest, [c | chars], acc)
  defp ident(rest, chars, acc), do: word(rest, chars, acc)

  # A word followed by a lone colon is a keyword key.
  defp word([?:, c | _] = rest, chars, acc) when c != ?: do
    lex(tl(rest), [{:kw, name(chars)} | acc])
  end

  defp word([?:], chars, acc), do: lex([], [{:kw, name(chars)} | acc])

  defp word(rest, chars, acc) do
    chars = :lists.reverse(chars)

    token =
      case Map.get(@keywords, chars) do
        nil -> literal_or_ident(chars)
        keyword -> keyword
      end

    lex(rest, [token | acc])
  end

  defp literal_or_ident(chars) do
    case Map.get(@literals, chars, :none) do
      :none -> {:ident, :erlang.list_to_atom(chars)}
      literal -> {:atom, literal}
    end
  end

  defp alias([c | rest], chars, acc) when is_word(c), do: alias(rest, [c | chars], acc)
  defp alias([?., c | rest], chars, acc) when is_upper(c), do: alias(rest, [c, ?. | chars], acc)

  defp alias(rest, chars, acc) do
    lex(rest, [{:alias, :erlang.list_to_atom(~c"Elixir." ++ :lists.reverse(chars))} | acc])
  end

  defp text(chars), do: :erlang.list_to_binary(:lists.reverse(chars))
  defp name(chars), do: :erlang.list_to_atom(:lists.reverse(chars))
end
