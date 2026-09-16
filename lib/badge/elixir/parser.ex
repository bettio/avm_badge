defmodule Badge.Elixir.Parser do
  @moduledoc """
  A small Elixir grammar over `Badge.Elixir.Lexer` tokens.

  Reads literals, variables, lists with `|` tails, tuples, maps, keyword
  lists, `Mod.fun(args)` and `:mod.fun(args)` calls, local calls, `f.(x)`,
  `&Mod.fun/n`, the usual operators, `|>`, `=` with destructuring, `^x`,
  `fn` with several clauses, `case` and `if`. Nodes are tagged tuples that
  `Badge.Elixir.Eval` walks; literals are `{:lit, term}` so a bare atom is
  never mistaken for a node.
  """

  @binary %{
    "=": {10, :right},
    "||": {20, :left},
    or: {20, :left},
    "&&": {30, :left},
    and: {30, :left},
    "==": {40, :left},
    "!=": {40, :left},
    "<": {40, :left},
    ">": {40, :left},
    "<=": {40, :left},
    ">=": {40, :left},
    "|>": {50, :left},
    in: {55, :left},
    "++": {60, :right},
    "--": {60, :right},
    "<>": {60, :right},
    "+": {70, :left},
    "-": {70, :left},
    "*": {80, :left},
    "/": {80, :left}
  }

  @doc "Parses a whole input into a list of expressions."
  @spec parse([term]) :: {:ok, [term]} | {:error, binary}
  def parse(tokens) do
    try do
      case block(tokens) do
        {exprs, []} -> {:ok, exprs}
        {_exprs, [token | _rest]} -> {:error, "unexpected " <> show(token)}
      end
    catch
      {:parse, reason} -> {:error, reason}
    end
  end

  # Expressions separated by seps, stopping before whatever closes the block
  # or before the head of the next clause.
  defp block(tokens), do: block(seps(tokens), [])

  defp block([], acc), do: {:lists.reverse(acc), []}
  defp block([token | _] = tokens, acc) when token == :end or token == :else, do: {:lists.reverse(acc), tokens}

  defp block(tokens, acc) do
    {expr, rest} = expr(tokens, 0)

    case rest do
      [:"->" | _] -> {:lists.reverse(acc), tokens}
      [:"," | _] -> {:lists.reverse(acc), tokens}
      [:sep | more] -> block(seps(more), [expr | acc])
      _ -> {:lists.reverse([expr | acc]), rest}
    end
  end

  defp seps([:sep | rest]), do: seps(rest)
  defp seps(tokens), do: tokens

  defp expr(tokens, min) do
    {left, rest} = unary(tokens)
    binary(left, rest, min)
  end

  defp binary(left, [op | rest] = tokens, min) when is_atom(op) do
    case Map.get(@binary, op) do
      {prec, assoc} when prec >= min ->
        next = if assoc == :left, do: prec + 1, else: prec
        {right, more} = expr(seps(rest), next)
        binary(combine(op, left, right), more, min)

      _other ->
        {left, tokens}
    end
  end

  defp binary(left, tokens, _min), do: {left, tokens}

  defp combine(:"=", left, right), do: {:match, left, right}
  defp combine(:"|>", left, {:call, mod, fun, args}), do: {:call, mod, fun, [left | args]}
  defp combine(:"|>", left, {:local, fun, args}), do: {:local, fun, [left | args]}
  defp combine(:"|>", left, {:apply, fun, args}), do: {:apply, fun, [left | args]}
  defp combine(:"|>", _left, _right), do: throw({:parse, "cannot pipe into that"})
  defp combine(:or, left, right), do: {:op, :"||", left, right}
  defp combine(:and, left, right), do: {:op, :"&&", left, right}
  defp combine(op, left, right), do: {:op, op, left, right}

  defp unary([:"-" | rest]) do
    case unary(rest) do
      {{:lit, n}, more} when is_number(n) -> {{:lit, -n}, more}
      {expr, more} -> {{:neg, expr}, more}
    end
  end

  defp unary([:"!" | rest]), do: wrap(:not, unary(rest))
  defp unary([:not | rest]), do: wrap(:not, unary(rest))
  defp unary([:"^", {:ident, name} | rest]), do: {{:pin, name}, rest}
  defp unary([:"&" | rest]), do: capture(rest)
  defp unary(tokens), do: postfix(primary(tokens))

  defp wrap(tag, {expr, rest}), do: {{tag, expr}, rest}

  defp capture([{:alias, mod}, :".", fun, :"/", {:int, arity} | rest]) do
    {{:capture, {:lit, mod}, fun_name(fun), arity}, rest}
  end

  defp capture([{:atom, mod}, :".", fun, :"/", {:int, arity} | rest]) do
    {{:capture, {:lit, mod}, fun_name(fun), arity}, rest}
  end

  defp capture([{:ident, fun}, :"/", {:int, arity} | rest]), do: {{:capture, nil, fun, arity}, rest}
  defp capture([{:int, n} | rest]), do: {{:arg, n}, rest}

  defp capture([:"(" | rest]) do
    {expr, more} = expr(seps(rest), 0)
    {{:capture_expr, expr, arity(expr, 0)}, expect(seps(more), :")")}
  end

  defp capture(_tokens), do: throw({:parse, "only &Mod.fun/n and &(...) captures"})

  # An operator after the dot names the function, as in `&Kernel.+/2`.
  defp fun_name({:ident, fun}), do: fun
  defp fun_name(op) when is_atom(op) and is_map_key(@binary, op), do: op
  defp fun_name(token), do: throw({:parse, "unexpected " <> show(token)})

  # The highest &n inside a capture body is its arity.
  defp arity({:arg, n}, max), do: max(n, max)
  defp arity(node, max) when is_tuple(node), do: arity(:erlang.tuple_to_list(node), max)
  defp arity([head | rest], max), do: arity(rest, arity(head, max))
  defp arity(_leaf, max), do: max

  defp primary([{:int, n} | rest]), do: {{:lit, n}, rest}
  defp primary([{:float, f} | rest]), do: {{:lit, f}, rest}
  defp primary([{:atom, a} | rest]), do: {{:lit, a}, rest}
  defp primary([{:string, s} | rest]), do: {{:lit, s}, rest}
  defp primary([{:alias, mod} | rest]), do: {{:lit, mod}, rest}

  defp primary([{:ident, name}, :"(" | rest]) do
    {args, more} = args(rest)
    {{:local, name, args}, more}
  end

  defp primary([{:ident, name} | rest]), do: {{:var, name}, rest}

  defp primary([:"(" | rest]) do
    {expr, more} = expr(seps(rest), 0)
    {expr, expect(seps(more), :")")}
  end

  defp primary([:"[" | rest]), do: list(rest)
  defp primary([:"{" | rest]), do: tuple(rest)
  defp primary([:"%{" | rest]), do: map(rest)

  defp primary([:fn | rest]) do
    {clauses, more} = clauses(rest)
    {{:fn, clauses}, more}
  end

  defp primary([:case | rest]) do
    {subject, more} = expr(rest, 0)
    {clauses, after_clauses} = clauses(expect(more, :do))
    {{:case, subject, clauses}, after_clauses}
  end

  defp primary([:if | rest]) do
    {condition, more} = expr(rest, 0)
    {yes, after_yes} = block(expect(more, :do))

    case after_yes do
      [:else | after_else] ->
        {no, after_no} = block(after_else)
        {{:if, condition, yes, no}, expect(after_no, :end)}

      _other ->
        {{:if, condition, yes, []}, expect(after_yes, :end)}
    end
  end

  defp primary([token | _rest]), do: throw({:parse, "unexpected " <> show(token)})
  defp primary([]), do: throw({:parse, "unexpected end"})

  defp postfix({expr, [:".", :"(" | rest]}) do
    {args, more} = args(rest)
    postfix({{:apply, expr, args}, more})
  end

  defp postfix({expr, [:".", fun, :"(" | rest]}) do
    {args, more} = args(rest)
    postfix({{:call, expr, fun_name(fun), args}, more})
  end

  defp postfix({expr, [:".", {:ident, fun} | rest]}), do: postfix({{:call, expr, fun, []}, rest})

  defp postfix(result), do: result

  # Call arguments: a trailing run of `key: value` becomes one keyword list.
  defp args(tokens) do
    {items, keywords, nil, rest} = items(tokens, :")")

    case keywords do
      [] -> {items, rest}
      _some -> {items ++ [{:list, keywords}], rest}
    end
  end

  defp list(tokens) do
    case items(tokens, :"]") do
      {items, keywords, nil, rest} -> {{:list, items ++ keywords}, rest}
      {items, [], tail, rest} -> {{:cons, items, tail}, rest}
      _other -> throw({:parse, "keywords go last"})
    end
  end

  defp tuple(tokens) do
    {items, keywords, nil, rest} = items(tokens, :"}")
    {{:tuple, items ++ keywords}, rest}
  end

  # Comma-separated expressions up to `closer`, as `{items, keywords, tail, rest}`;
  # only a list may end in `| tail`.
  defp items(tokens, closer), do: items(seps(tokens), closer, [])

  defp items([closer | rest], closer, acc), do: {:lists.reverse(acc), [], nil, rest}
  defp items([{:kw, _key} | _] = tokens, closer, acc), do: keywords(tokens, closer, :lists.reverse(acc), [])

  defp items(tokens, closer, acc) do
    {expr, rest} = expr(tokens, 0)

    case seps(rest) do
      [:"," | more] -> items(seps(more), closer, [expr | acc])
      [:"|" | more] when closer == :"]" -> tail(seps(more), :lists.reverse([expr | acc]))
      [^closer | more] -> {:lists.reverse([expr | acc]), [], nil, more}
      _other -> throw({:parse, "expected " <> show(closer)})
    end
  end

  defp tail(tokens, heads) do
    {expr, rest} = expr(tokens, 0)
    {heads, [], expr, expect(seps(rest), :"]")}
  end

  defp keywords([{:kw, key} | rest], closer, items, acc) do
    {expr, more} = expr(seps(rest), 0)
    pair = {:tuple, [{:lit, key}, expr]}

    case seps(more) do
      [:"," | after_comma] -> keywords(seps(after_comma), closer, items, [pair | acc])
      [^closer | after_closer] -> {items, :lists.reverse([pair | acc]), nil, after_closer}
      _other -> throw({:parse, "expected " <> show(closer)})
    end
  end

  defp keywords(_tokens, _closer, _items, _acc), do: throw({:parse, "keywords go last"})

  defp map(tokens) do
    case seps(tokens) do
      [:"}" | rest] -> {{:map, []}, rest}
      [{:kw, _key} | _] = pairs -> map_pairs(pairs, [])
      other -> map_first(other)
    end
  end

  defp map_first(tokens) do
    {expr, rest} = expr(tokens, 0)

    case seps(rest) do
      [:"=>" | more] -> map_value(expr, seps(more), [])
      [:"|" | more] -> map_update(expr, seps(more))
      _other -> throw({:parse, "expected =>"})
    end
  end

  defp map_update(target, tokens) do
    {{:map, pairs}, rest} = map(tokens)
    {{:map_update, target, pairs}, rest}
  end

  defp map_pairs([:"}" | rest], acc), do: {{:map, :lists.reverse(acc)}, rest}

  defp map_pairs([{:kw, key} | rest], acc), do: map_value({:lit, key}, seps(rest), acc)

  defp map_pairs(tokens, acc) do
    {key, rest} = expr(tokens, 0)
    map_value(key, expect(seps(rest), :"=>"), acc)
  end

  defp map_value(key, tokens, acc) do
    {value, rest} = expr(seps(tokens), 0)

    case seps(rest) do
      [:"," | more] -> map_pairs(seps(more), [{key, value} | acc])
      [:"}" | more] -> {{:map, :lists.reverse([{key, value} | acc])}, more}
      _other -> throw({:parse, "expected }"})
    end
  end

  # `patterns -> body` up to `end`; a body ends where the next head begins.
  defp clauses(tokens), do: clauses(seps(tokens), [])

  defp clauses([:end | rest], acc), do: {:lists.reverse(acc), rest}
  defp clauses([], _acc), do: throw({:parse, "expected end"})

  defp clauses(tokens, acc) do
    {patterns, rest} = patterns(tokens, [])
    {body, more} = block(rest)
    clauses(seps(more), [{patterns, body} | acc])
  end

  defp patterns([:"->" | rest], []), do: {[], rest}

  defp patterns(tokens, acc) do
    {pattern, rest} = expr(tokens, 11)

    case rest do
      [:"," | more] -> patterns(more, [pattern | acc])
      [:"->" | more] -> {:lists.reverse([pattern | acc]), more}
      _other -> throw({:parse, "expected ->"})
    end
  end

  defp expect([token | rest], token), do: rest
  defp expect(_tokens, token), do: throw({:parse, "expected " <> show(token)})

  defp show({_tag, value}) when is_binary(value), do: value
  defp show({_tag, value}) when is_integer(value), do: :erlang.integer_to_binary(value)
  defp show({_tag, value}) when is_float(value), do: :erlang.float_to_binary(value)
  defp show({_tag, value}) when is_atom(value), do: :erlang.atom_to_binary(value, :latin1)
  defp show(token), do: :erlang.atom_to_binary(token, :latin1)
end
