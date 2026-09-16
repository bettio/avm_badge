defmodule Badge.Elixir.Eval do
  @moduledoc """
  Walks `Badge.Elixir.Parser` nodes against a map of bindings.

  Every function returns `{value, bindings}` and raises the way the code
  would have, so the caller catches `error`, `throw` and `exit` alike. A
  `fn` becomes a real function, so it can be handed to `Enum` or spawned.
  """

  @doc "Evaluates expressions in order, returning the last value."
  @spec run([term], map) :: {term, map}
  def run([], bindings), do: {nil, bindings}
  def run([expr], bindings), do: eval(expr, bindings)

  def run([expr | rest], bindings) do
    {_value, bindings} = eval(expr, bindings)
    run(rest, bindings)
  end

  @doc "Evaluates one expression."
  @spec eval(term, map) :: {term, map}
  def eval({:lit, value}, bindings), do: {value, bindings}
  def eval({:var, name}, bindings), do: {fetch(name, bindings), bindings}
  def eval({:pin, name}, bindings), do: {fetch(name, bindings), bindings}

  def eval({:match, pattern, expr}, bindings) do
    {value, bindings} = eval(expr, bindings)

    case match(pattern, value, bindings) do
      {:ok, bound} -> {value, bound}
      :nomatch -> :erlang.error({:badmatch, value})
    end
  end

  def eval({:op, :"&&", left, right}, bindings) do
    {value, bindings} = eval(left, bindings)
    if truthy?(value), do: eval(right, bindings), else: {value, bindings}
  end

  def eval({:op, :"||", left, right}, bindings) do
    {value, bindings} = eval(left, bindings)
    if truthy?(value), do: {value, bindings}, else: eval(right, bindings)
  end

  def eval({:op, op, left, right}, bindings) do
    {a, bindings} = eval(left, bindings)
    {b, bindings} = eval(right, bindings)
    {operate(op, a, b), bindings}
  end

  def eval({:neg, expr}, bindings) do
    {value, bindings} = eval(expr, bindings)
    {-value, bindings}
  end

  def eval({:not, expr}, bindings) do
    {value, bindings} = eval(expr, bindings)
    {not truthy?(value), bindings}
  end

  def eval({:list, items}, bindings), do: each(items, bindings)

  def eval({:cons, heads, tail}, bindings) do
    {items, bindings} = each(heads, bindings)
    {rest, bindings} = eval(tail, bindings)
    {items ++ rest, bindings}
  end

  def eval({:tuple, items}, bindings) do
    {values, bindings} = each(items, bindings)
    {:erlang.list_to_tuple(values), bindings}
  end

  def eval({:map, pairs}, bindings) do
    {list, bindings} = pairs(pairs, bindings, [])
    {:maps.from_list(list), bindings}
  end

  def eval({:map_update, target, pairs}, bindings) do
    {map, bindings} = eval(target, bindings)
    {list, bindings} = pairs(pairs, bindings, [])
    {update(list, map), bindings}
  end

  def eval({:call, target, fun, args}, bindings) do
    {mod, bindings} = eval(target, bindings)
    {values, bindings} = each(args, bindings)
    {call(mod, fun, values), bindings}
  end

  def eval({:local, fun, args}, bindings) do
    {values, bindings} = each(args, bindings)
    {local(fun, values), bindings}
  end

  def eval({:apply, target, args}, bindings) do
    {fun, bindings} = eval(target, bindings)
    {values, bindings} = each(args, bindings)
    is_function(fun) or :erlang.error({:badfun, fun})
    {apply(fun, values), bindings}
  end

  def eval({:fn, clauses}, bindings), do: {closure(clauses, bindings), bindings}

  def eval({:capture, nil, fun, arity}, bindings) do
    {wrap(arity, fn args -> local(fun, args) end), bindings}
  end

  def eval({:capture, target, fun, arity}, bindings) do
    {mod, bindings} = eval(target, bindings)
    {wrap(arity, fn args -> apply(mod, fun, args) end), bindings}
  end

  # `&(&1 + &2)`: the arguments are bound under `{:arg, n}` for the body.
  def eval({:capture_expr, body, arity}, bindings) do
    call = fn args ->
      {value, _inner} = eval(body, args(args, 1, bindings))
      value
    end

    {wrap(arity, call), bindings}
  end

  def eval({:arg, n}, bindings), do: {fetch({:arg, n}, bindings), bindings}

  # Bindings made inside a case or if stay inside, as in Elixir.
  def eval({:case, subject, clauses}, bindings) do
    {value, bindings} = eval(subject, bindings)
    {dispatch(clauses, [value], bindings, {:case_clause, value}), bindings}
  end

  def eval({:if, condition, yes, no}, bindings) do
    {value, bindings} = eval(condition, bindings)
    {result, _inner} = run(if(truthy?(value), do: yes, else: no), bindings)
    {result, bindings}
  end

  @doc """
  Matches a pattern against a value.

  Returns `{:ok, bindings}` with whatever the pattern bound, or `:nomatch`.
  """
  @spec match(term, term, map) :: {:ok, map} | :nomatch
  def match(pattern, value, bindings) do
    try do
      {:ok, bind(pattern, value, bindings)}
    catch
      :nomatch -> :nomatch
    end
  end

  defp bind({:var, :_}, _value, bindings), do: bindings
  defp bind({:var, name}, value, bindings), do: Map.put(bindings, name, value)
  defp bind({:pin, name}, value, bindings), do: same(fetch(name, bindings), value, bindings)
  defp bind({:lit, literal}, value, bindings), do: same(literal, value, bindings)

  defp bind({:list, patterns}, value, bindings) when is_list(value) do
    length(patterns) == length(value) or throw(:nomatch)
    bind_each(patterns, value, bindings)
  end

  defp bind({:cons, patterns, tail}, value, bindings) when is_list(value) do
    {heads, rest} = split(length(patterns), value)
    bind(tail, rest, bind_each(patterns, heads, bindings))
  end

  defp bind({:tuple, patterns}, value, bindings) when is_tuple(value) do
    length(patterns) == :erlang.tuple_size(value) or throw(:nomatch)
    bind_each(patterns, :erlang.tuple_to_list(value), bindings)
  end

  defp bind({:map, pairs}, value, bindings) when is_map(value) do
    :lists.foldl(
      fn {key_pattern, pattern}, acc ->
        {key, _acc} = eval(key_pattern, acc)

        case Map.fetch(value, key) do
          {:ok, found} -> bind(pattern, found, acc)
          :error -> throw(:nomatch)
        end
      end,
      bindings,
      pairs
    )
  end

  defp bind({:op, :"<>", {:lit, prefix}, pattern}, value, bindings) when is_binary(value) do
    size = byte_size(prefix)
    byte_size(value) >= size or throw(:nomatch)
    same(prefix, :binary.part(value, 0, size), bindings)
    bind(pattern, :binary.part(value, size, byte_size(value) - size), bindings)
  end

  defp bind({:list, _patterns}, _value, _bindings), do: throw(:nomatch)
  defp bind({:cons, _patterns, _tail}, _value, _bindings), do: throw(:nomatch)
  defp bind({:tuple, _patterns}, _value, _bindings), do: throw(:nomatch)
  defp bind({:map, _pairs}, _value, _bindings), do: throw(:nomatch)
  defp bind({:op, :<>, {:lit, _prefix}, _pattern}, _value, _bindings), do: throw(:nomatch)
  defp bind(_pattern, _value, _bindings), do: :erlang.error(:bad_pattern)

  defp bind_each([], [], bindings), do: bindings

  defp bind_each([pattern | patterns], [value | values], bindings) do
    bind_each(patterns, values, bind(pattern, value, bindings))
  end

  defp same(a, b, bindings) do
    if a === b, do: bindings, else: throw(:nomatch)
  end

  defp split(n, list), do: split(n, list, [])
  defp split(0, rest, acc), do: {:lists.reverse(acc), rest}
  defp split(_n, [], _acc), do: throw(:nomatch)
  defp split(n, [head | rest], acc), do: split(n - 1, rest, [head | acc])

  defp each(exprs, bindings), do: each(exprs, bindings, [])
  defp each([], bindings, acc), do: {:lists.reverse(acc), bindings}

  defp each([expr | rest], bindings, acc) do
    {value, bindings} = eval(expr, bindings)
    each(rest, bindings, [value | acc])
  end

  defp pairs([], bindings, acc), do: {:lists.reverse(acc), bindings}

  defp pairs([{key_expr, value_expr} | rest], bindings, acc) do
    {key, bindings} = eval(key_expr, bindings)
    {value, bindings} = eval(value_expr, bindings)
    pairs(rest, bindings, [{key, value} | acc])
  end

  defp update([], map), do: map

  defp update([{key, value} | rest], map) do
    :erlang.is_map_key(key, map) or :erlang.error({:badkey, key})
    update(rest, Map.put(map, key, value))
  end

  defp args([], _n, bindings), do: bindings
  defp args([value | rest], n, bindings), do: args(rest, n + 1, Map.put(bindings, {:arg, n}, value))

  defp fetch(name, bindings) do
    case Map.fetch(bindings, name) do
      {:ok, value} -> value
      :error -> :erlang.error({:unbound, name})
    end
  end

  defp truthy?(value), do: value != false and value != nil

  defp operate(:+, a, b), do: a + b
  defp operate(:-, a, b), do: a - b
  defp operate(:*, a, b), do: a * b
  defp operate(:/, a, b), do: a / b
  defp operate(:==, a, b), do: a == b
  defp operate(:!=, a, b), do: a != b
  defp operate(:<, a, b), do: a < b
  defp operate(:>, a, b), do: a > b
  defp operate(:<=, a, b), do: a <= b
  defp operate(:>=, a, b), do: a >= b
  defp operate(:++, a, b), do: a ++ b
  defp operate(:--, a, b), do: a -- b
  defp operate(:<>, a, b) when is_binary(a) and is_binary(b), do: <<a::binary, b::binary>>
  defp operate(:<>, a, b), do: :erlang.error({:badarg, {a, b}})
  defp operate(:in, a, b), do: :lists.member(a, b)

  # `map.key` reads a field; anything else after a dot is a remote call.
  defp call(map, key, []) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> :erlang.error({:badkey, key})
    end
  end

  defp call(mod, fun, args) when is_atom(mod), do: apply(mod, fun, args)
  defp call(other, _fun, _args), do: :erlang.error({:badmodule, other})

  # Local calls: what Kernel would inline, then the BIFs, then Kernel's own.
  defp local(:elem, [tuple, index]), do: :erlang.element(index + 1, tuple)
  defp local(:put_elem, [tuple, index, value]), do: :erlang.setelement(index + 1, tuple, value)
  defp local(:to_string, [value]), do: apply(String.Chars, :to_string, [value])
  defp local(:inspect, [value]), do: apply(Kernel, :inspect, [value])
  defp local(:raise, [message]), do: :erlang.error(message)

  defp local(fun, args) do
    arity = length(args)

    cond do
      :erlang.function_exported(:erlang, fun, arity) -> apply(:erlang, fun, args)
      :erlang.function_exported(Kernel, fun, arity) -> apply(Kernel, fun, args)
      true -> :erlang.error({:undef, fun, arity})
    end
  end

  defp closure([{patterns, _body} | _] = clauses, bindings) do
    arity = length(patterns)

    :lists.all(fn {ps, _b} -> length(ps) == arity end, clauses) or
      :erlang.error(:clauses_differ_in_arity)

    wrap(arity, fn args -> dispatch(clauses, args, bindings, :function_clause) end)
  end

  defp dispatch([], _args, _bindings, reason), do: :erlang.error(reason)

  defp dispatch([{patterns, body} | rest], args, bindings, reason) do
    case match_all(patterns, args, bindings) do
      {:ok, bound} ->
        {value, _bindings} = run(body, bound)
        value

      :nomatch ->
        dispatch(rest, args, bindings, reason)
    end
  end

  defp match_all(patterns, values, bindings) do
    try do
      {:ok, bind_each(patterns, values, bindings)}
    catch
      :nomatch -> :nomatch
    end
  end

  # A real function of the right arity around a call taking an argument list.
  defp wrap(0, call), do: fn -> call.([]) end
  defp wrap(1, call), do: fn a -> call.([a]) end
  defp wrap(2, call), do: fn a, b -> call.([a, b]) end
  defp wrap(3, call), do: fn a, b, c -> call.([a, b, c]) end
  defp wrap(4, call), do: fn a, b, c, d -> call.([a, b, c, d]) end
  defp wrap(arity, _call), do: :erlang.error({:arity_too_large, arity})
end
