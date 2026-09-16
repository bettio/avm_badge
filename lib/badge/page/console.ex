defmodule Badge.Page.Console do
  @moduledoc """
  A prompt for `Badge.Elixir`.

  The last row is the input line; what came before scrolls up above it,
  newest at the bottom. Enter sends the line, up and down walk the lines
  sent before, left and right move within the line. A worker process owns
  the bindings; a line that has not answered after a few seconds is killed,
  and its bindings with it.
  """

  use Badge.Page

  alias Badge.Field
  alias Badge.Theme

  @x 8
  @top Theme.content_top() + 4
  @pitch 16
  @char_w 8
  @columns div(Theme.width() - 2 * @x, @char_w)
  @rows div(Theme.height() - @top, @pitch)
  @scrollback @rows - 1
  @input_y @top + @scrollback * @pitch

  @keep 40
  @capacity 120
  @history 20
  @timeout_ticks 50

  @impl true
  def title, do: "Console"

  @impl true
  def icon, do: :square

  @impl true
  def init do
    Map.merge(fresh(), %{lines: [], field: Field.new(@capacity), history: [], recall: 0})
  end

  @impl true
  def leave(state), do: Badge.Elixir.stop(state.worker)

  @impl true
  def handle_key({:char, char}, state), do: {:ok, edit(state, Field.insert(state.field, char))}
  def handle_key({:edit, :backspace}, state), do: {:ok, edit(state, Field.backspace(state.field))}
  def handle_key({:move, :left}, state), do: {:ok, edit(state, Field.left(state.field))}
  def handle_key({:move, :right}, state), do: {:ok, edit(state, Field.right(state.field))}
  def handle_key({:move, :up}, state), do: {:ok, recall(state, state.recall + 1)}
  def handle_key({:move, :down}, state), do: {:ok, recall(state, state.recall - 1)}

  def handle_key({:edit, :newline}, %{busy: 0} = state), do: {:ok, submit(state)}
  def handle_key({:edit, :newline}, _state), do: :ignore

  def handle_key(_event, _state), do: :ignore

  @impl true
  def handle_info({:console, worker, result}, %{worker: worker} = state) do
    {:ok, answered(state, result)}
  end

  def handle_info(_message, _state), do: :ignore

  @impl true
  def tick(%{busy: 0} = state), do: state
  def tick(%{busy: busy} = state) when busy > @timeout_ticks, do: timed_out(state)
  def tick(%{busy: busy} = state), do: %{state | busy: busy + 1}

  @impl true
  def render(state) do
    [cursor(state), input(state) | output(state)]
  end

  @doc "The visible rows of output, oldest first, as `{kind, text}`."
  def window(lines), do: window(lines, @scrollback, [])

  @doc "How many rows of output fit above the input line."
  def visible_rows, do: @scrollback

  defp fresh, do: %{session: Badge.Elixir.new(), worker: Badge.Elixir.start(self()), busy: 0}

  defp edit(state, field), do: %{state | field: field}

  defp submit(state) do
    line = Field.value(state.field)
    state = push(state, :in, prompt(state) <> line)
    history = remember(state.history, line)
    state = %{state | field: Field.new(@capacity), history: history, recall: 0}

    case Badge.Elixir.feed(state.session, line) do
      {:pending, session} ->
        %{state | session: session}

      {:error, session, text} ->
        %{push(state, :err, text) | session: session}

      {:eval, session, exprs} ->
        Badge.Elixir.eval(state.worker, exprs)
        %{state | session: session, busy: 1}
    end
  end

  defp answered(state, {:ok, text}), do: %{push(state, :out, text) | busy: 0}
  defp answered(state, {:error, text}), do: %{push(state, :err, text) | busy: 0}

  defp timed_out(state) do
    Badge.Elixir.stop(state.worker)
    Map.merge(push(state, :err, "timeout, bindings lost"), fresh())
  end

  defp remember(history, <<>>), do: history
  defp remember(history, line), do: :lists.sublist([line | history], @history)

  defp recall(state, index) when index < 0, do: state
  defp recall(state, index) when index > length(state.history), do: state
  defp recall(state, 0), do: %{state | field: Field.new(@capacity), recall: 0}

  defp recall(state, index) do
    chars = :erlang.binary_to_list(:lists.nth(index, state.history))
    field = :lists.foldl(&Field.insert(&2, &1), Field.new(@capacity), chars)

    %{state | field: field, recall: index}
  end

  defp push(state, kind, text) do
    %{state | lines: :lists.sublist([{kind, text} | state.lines], @keep)}
  end

  defp prompt(%{busy: busy}) when busy > 0, do: "* "

  defp prompt(state) do
    if Badge.Elixir.pending?(state.session), do: "..> ", else: "ex> "
  end

  defp input(state) do
    {shown, _start} = visible(state)

    {:text, @x, @input_y, :default16px, Theme.fg(), Theme.bg(), prompt(state) <> shown}
  end

  defp cursor(state) do
    {_shown, start} = visible(state)
    column = byte_size(prompt(state)) + Field.cursor(state.field) - start

    {:rect, @x + column * @char_w, @input_y + @pitch - 2, @char_w, 2, Theme.fg()}
  end

  # The stretch of the line that fits after the prompt, keeping the cursor in view.
  defp visible(state) do
    value = Field.value(state.field)
    width = @columns - byte_size(prompt(state))
    start = max(Field.cursor(state.field) - width + 1, 0)
    length = min(width, byte_size(value) - start)

    {:binary.part(value, start, length), start}
  end

  defp output(state), do: items(window(state.lines), @top, [])

  defp items([], _y, acc), do: :lists.reverse(acc)

  defp items([{kind, text} | rest], y, acc) do
    items(rest, y + @pitch, [{:text, @x, y, :default16px, colour(kind), Theme.bg(), text} | acc])
  end

  defp colour(:in), do: Theme.muted()
  defp colour(:out), do: Theme.fg()
  defp colour(:err), do: Theme.alert()

  # Newest first in, oldest first out; only as many lines are wrapped as fit.
  defp window([], _need, acc), do: acc
  defp window(_lines, need, acc) when need <= 0, do: acc

  defp window([{kind, text} | rest], need, acc) do
    rows = chunks(text, kind, [])
    extra = length(rows) - need
    rows = if extra > 0, do: :lists.nthtail(extra, rows), else: rows

    window(rest, need - length(rows), rows ++ acc)
  end

  defp chunks(text, kind, acc) when byte_size(text) <= @columns do
    :lists.reverse([{kind, text} | acc])
  end

  defp chunks(<<head::binary-size(@columns), rest::binary>>, kind, acc) do
    chunks(rest, kind, [{kind, head} | acc])
  end
end
