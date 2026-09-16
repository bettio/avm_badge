defmodule Badge.Page.ConsoleTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Console
  alias Badge.Theme

  @input_y Theme.content_top() + 4 + Console.visible_rows() * 16

  setup do
    state = Console.init()
    on_exit(fn -> Console.leave(state) end)
    %{state: state}
  end

  defp type(state, string) do
    :lists.foldl(
      fn char, acc ->
        {:ok, next} = Console.handle_key({:char, char}, acc)
        next
      end,
      state,
      :erlang.binary_to_list(string)
    )
  end

  defp key(state, event) do
    {:ok, next} = Console.handle_key(event, state)
    next
  end

  defp enter(state), do: key(state, {:edit, :newline})

  defp worker(state), do: state.worker

  # Sends a line and applies the worker's answer, as Badge.UI would.
  defp evaluate(state, line) do
    state = enter(type(state, line))
    worker = worker(state)
    assert_receive {:console, ^worker, _result} = message
    {:ok, next} = Console.handle_info(message, state)
    next
  end

  defp texts(items), do: for({:text, _x, _y, _f, _fg, _bg, body} <- items, do: body)

  defp input_line(items) do
    [line] = for {:text, _x, @input_y, _f, _fg, _bg, body} <- items, do: body
    line
  end

  defp cursor_x(items) do
    [{:rect, x, _y, 8, 2, _c} | _rest] = items
    x
  end

  describe "identity" do
    test "sits on the square of the third home screen" do
      assert Console.title() == "Console"
      assert Console.icon() == :square
      assert Badge.Pages.for_key(:square, 2) == Console
    end
  end

  describe "init/0 and leave/1" do
    test "starts a worker and leave kills it", %{state: state} do
      ref = Process.monitor(state.worker)

      Console.leave(state)

      assert_receive {:DOWN, ^ref, :process, _pid, :killed}
    end

    test "shows the Elixir prompt", %{state: state} do
      assert input_line(Console.render(state)) == "ex> "
    end
  end

  describe "typing" do
    test "characters go on the input line after the prompt", %{state: state} do
      assert input_line(Console.render(type(state, "1 + 2"))) == "ex> 1 + 2"
    end

    test "backspace removes the last character", %{state: state} do
      state = state |> type("ab") |> key({:edit, :backspace})

      assert input_line(Console.render(state)) == "ex> a"
    end

    test "left and right move the cursor", %{state: state} do
      state = type(state, "ab")
      at_end = cursor_x(Console.render(state))
      state = key(state, {:move, :left})

      assert cursor_x(Console.render(state)) == at_end - 8
      assert cursor_x(Console.render(key(state, {:move, :right}))) == at_end
    end

    test "a long line scrolls so the cursor stays on screen", %{state: state} do
      items = Console.render(type(state, :erlang.list_to_binary(:lists.duplicate(50, ?x))))

      assert byte_size(input_line(items)) == 38 - 1
      assert cursor_x(items) <= Theme.width() - 8
    end

    test "tab is ignored", %{state: state} do
      assert Console.handle_key({:edit, :tab}, state) == :ignore
    end
  end

  describe "sending" do
    test "echoes the line and shows the result", %{state: state} do
      items = Console.render(evaluate(state, "1 + 2"))

      assert "ex> 1 + 2" in texts(items)
      assert "3" in texts(items)
      assert input_line(items) == "ex> "
    end

    test "bindings persist across lines", %{state: state} do
      state = state |> evaluate("x = 5") |> evaluate("x * 2")

      assert "10" in texts(Console.render(state))
    end

    test "an open bracket changes the prompt and completes later", %{state: state} do
      state = enter(type(state, "[1,"))

      assert input_line(Console.render(state)) == "..> "
      assert "[1, 2]" in texts(Console.render(evaluate(state, "2]")))
    end

    test "a busy worker shows a waiting prompt and refuses another line", %{state: state} do
      state = enter(type(state, "1 + 2"))

      assert input_line(Console.render(state)) == "* "
      assert Console.handle_key({:edit, :newline}, type(state, "1")) == :ignore
    end

    test "errors are shown in the alert colour", %{state: state} do
      state = evaluate(state, "nope")

      assert Enum.any?(Console.render(state), fn
               {:text, _x, _y, _f, fg, _bg, "** (CompileError) undefined variable n"} ->
                 fg == Theme.alert()

               _item ->
                 false
             end)
    end
  end

  describe "handle_info/2" do
    test "answers from an unknown worker are ignored", %{state: state} do
      assert Console.handle_info({:console, self(), {:ok, "1"}}, state) == :ignore
    end
  end

  describe "history" do
    test "up recalls earlier lines and down returns to an empty one", %{state: state} do
      state = state |> evaluate("1") |> evaluate("2") |> key({:move, :up})

      assert input_line(Console.render(state)) == "ex> 2"
      state = key(state, {:move, :up})
      assert input_line(Console.render(state)) == "ex> 1"
      assert input_line(Console.render(key(state, {:move, :up}))) == "ex> 1"
      state = state |> key({:move, :down}) |> key({:move, :down})
      assert input_line(Console.render(state)) == "ex> "
    end

    test "empty lines are not remembered", %{state: state} do
      state = state |> enter() |> key({:move, :up})

      assert input_line(Console.render(state)) == "ex> "
    end
  end

  describe "tick/1" do
    test "is inert while idle", %{state: state} do
      assert Console.tick(state) == state
    end

    test "kills a line that runs too long and starts a fresh worker", %{state: state} do
      state = enter(type(state, "Process.sleep(60000)"))
      old = worker(state)
      ref = Process.monitor(old)

      state = :lists.foldl(fn _n, acc -> Console.tick(acc) end, state, :lists.seq(1, 51))

      assert_receive {:DOWN, ^ref, :process, ^old, :killed}
      assert worker(state) != old
      assert state.busy == 0
      assert "timeout, bindings lost" in texts(Console.render(state))
      Console.leave(state)
    end
  end

  describe "render/1" do
    test "the cursor is the first item", %{state: state} do
      assert [{:rect, _x, _y, 8, 2, _c} | _rest] = Console.render(state)
    end

    test "output wraps to the panel width and keeps only what fits" do
      long = :erlang.list_to_binary(:lists.duplicate(100, ?a))
      lines = for n <- 1..20, do: {:out, long <> :erlang.integer_to_binary(n)}

      rows = Console.window(lines)

      assert length(rows) == Console.visible_rows()
      assert Enum.all?(rows, fn {:out, text} -> byte_size(text) <= 38 end)
      assert :lists.last(rows) == {:out, :erlang.list_to_binary(:lists.duplicate(24, ?a)) <> "1"}
    end

    test "content starts below the title bar", %{state: state} do
      items = Console.render(evaluate(state, "1"))
      ys = for {:text, _x, y, _f, _fg, _bg, _body} <- items, do: y

      assert :lists.min(ys) >= Theme.content_top()
    end
  end
end
