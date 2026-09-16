defmodule Badge.Elixir do
  @moduledoc """
  Line-at-a-time front end to a small Elixir interpreter.

  Not the compiler: `Badge.Elixir.Lexer`, `Badge.Elixir.Parser` and
  `Badge.Elixir.Eval` read a subset by hand, since the real one cannot fit
  on the badge. A session holds lines until their brackets and `do`
  blocks close. Evaluation runs in a worker from `start/1`, which owns the
  bindings and answers the process that started it with
  `{:console, worker, {:ok, text} | {:error, text}}`.
  """

  alias Badge.Elixir.Eval
  alias Badge.Elixir.Lexer
  alias Badge.Elixir.Parser

  @max_output 240

  @doc "A session with nothing pending."
  def new, do: %{lines: []}

  @doc "Whether an expression is waiting for more lines."
  def pending?(session), do: session.lines != []

  @doc """
  Adds a line to the session.

  Returns `{:eval, session, exprs}` when the input is complete, `{:pending,
  session}` when brackets or blocks are still open, and `{:error, session,
  text}` when it could not be read; the session is then reset.
  """
  def feed(session, line) do
    lines = [line | session.lines]

    case {Lexer.tokenize(line), Lexer.tokenize(join(:lists.reverse(lines)))} do
      {{:ok, []}, _all} -> {:pending, session}
      {_own, {:error, text}} -> {:error, new(), text}
      {_own, {:ok, tokens}} -> feed_tokens(lines, tokens)
    end
  end

  defp feed_tokens(lines, tokens) do
    case depth(tokens, 0) do
      depth when depth > 0 -> {:pending, %{lines: lines}}
      depth when depth < 0 -> {:error, new(), "unexpected end"}
      0 -> parsed(tokens)
    end
  end

  defp parsed(tokens) do
    case Parser.parse(tokens) do
      {:ok, exprs} -> {:eval, new(), exprs}
      {:error, text} -> {:error, new(), text}
    end
  end

  @doc "Spawns a worker that evaluates for `owner`."
  def start(owner), do: spawn(fn -> loop(owner, %{}) end)

  @doc "Asks the worker to evaluate parsed expressions."
  def eval(worker, exprs), do: send(worker, {:eval, exprs})

  @doc "Kills the worker, and every binding it held."
  def stop(worker), do: :erlang.exit(worker, :kill)

  @doc "Evaluates expressions against bindings, returning text and the new bindings."
  def run(exprs, bindings) do
    try do
      {value, bound} = Eval.run(exprs, bindings)
      {{:ok, format(value)}, bound}
    catch
      kind, reason -> {{:error, describe(kind, reason)}, bindings}
    end
  end

  @doc "A term as `inspect/1` shows it, clipped to a screenful."
  def format(term) do
    try do
      clip(apply(Kernel, :inspect, [term]))
    catch
      _kind, _reason -> "#unprintable"
    end
  end

  defp loop(owner, bindings) do
    receive do
      {:eval, exprs} ->
        {result, bindings} = run(exprs, bindings)
        send(owner, {:console, self(), result})
        loop(owner, bindings)
    end
  end

  defp join([line]), do: line
  defp join([line | rest]), do: <<line::binary, ?\n, join(rest)::binary>>

  defp depth([], acc), do: acc
  defp depth([token | rest], acc) when token in [:"(", :"[", :"{", :"%{", :fn, :do], do: depth(rest, acc + 1)
  defp depth([token | rest], acc) when token in [:")", :"]", :"}", :end], do: depth(rest, acc - 1)
  defp depth([_token | rest], acc), do: depth(rest, acc)

  defp describe(:error, {:badmatch, value}), do: "** (MatchError) no match: " <> format(value)
  defp describe(:error, {:unbound, {:arg, n}}), do: "** (CompileError) no &" <> :erlang.integer_to_binary(n)

  defp describe(:error, {:unbound, name}) do
    "** (CompileError) undefined variable " <> :erlang.atom_to_binary(name, :latin1)
  end
  defp describe(:error, {:undef, fun, arity}), do: "** (UndefinedFunctionError) " <> mfa(fun, arity)
  defp describe(:error, :undef), do: "** (UndefinedFunctionError) no such function"
  defp describe(:error, :function_clause), do: "** (FunctionClauseError) no clause matching"
  defp describe(:error, {:case_clause, value}), do: "** (CaseClauseError) no clause matching: " <> format(value)
  defp describe(:error, :badarith), do: "** (ArithmeticError) bad argument in arithmetic"
  defp describe(:error, {:badkey, key}), do: "** (KeyError) key " <> format(key) <> " not found"
  defp describe(:error, {:badmodule, value}), do: "** (ArgumentError) not a module: " <> format(value)
  defp describe(:error, {:badfun, value}), do: "** (BadFunctionError) not a function: " <> format(value)
  defp describe(:error, :bad_pattern), do: "** (CompileError) invalid pattern"
  defp describe(:error, reason), do: "** (error) " <> format(reason)
  defp describe(:throw, value), do: "** (throw) " <> format(value)
  defp describe(:exit, reason), do: "** (exit) " <> format(reason)

  defp mfa(fun, arity) do
    :erlang.atom_to_binary(fun, :latin1) <> "/" <> :erlang.integer_to_binary(arity)
  end

  defp clip(text) when byte_size(text) <= @max_output, do: text
  defp clip(text), do: :binary.part(text, 0, @max_output - 3) <> "..."
end
