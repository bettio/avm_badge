defmodule Badge.Page.RaycasterTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Raycaster
  alias Badge.Theme

  describe "identity" do
    test "names itself for the home grid" do
      assert Raycaster.title() == "Raycaster"
      assert Raycaster.icon() in Badge.Icons.names()
    end

    test "asks for the shortest gap the ticker offers" do
      assert Raycaster.refresh(Raycaster.init()) == 100
    end

    test "starts standing still" do
      assert %{at: nil} = Raycaster.init()
    end
  end

  describe "the keys the engine reads" do
    # The firmware's labels are charlists, and the engine has to know them.
    test "every direction moves or turns the player" do
      grid = Elixir.Raycaster.Engine.grid()
      start = %{x: 11 * 256 + 128, y: 9 * 256 + 128, a: 0}

      for label <- [~c"Up", ~c"W", ~c"Down", ~c"S", ~c"Q", ~c"E", ~c"Left", ~c"A", ~c"Right", ~c"D"] do
        refute Elixir.Raycaster.Engine.step(grid, start, [label], 200) == start
      end
    end

    test "keys with no meaning here change nothing" do
      grid = Elixir.Raycaster.Engine.grid()
      start = %{x: 11 * 256 + 128, y: 9 * 256 + 128, a: 0}

      assert Elixir.Raycaster.Engine.step(grid, start, [~c"Space", ~c"Ctrl", ~c"1"], 200) == start
    end
  end

  describe "render/1" do
    test "stays inside the content area, below the title bar" do
      items = Raycaster.render(Raycaster.init())

      assert items != []

      for {:rect, x, y, w, h, _colour} <- items do
        assert x >= 0 and x + w <= Theme.width()
        assert y >= Theme.content_top() and y + h <= Theme.height()
      end
    end

    test "draws no background, which is the router's job" do
      items = Raycaster.render(Raycaster.init())
      rects = for {:rect, 0, y, w, h, _} <- items, w == Theme.width(), do: {y, h}

      # Only the floor and ceiling span the panel, and together they fill the view only.
      assert length(rects) == 2
      assert rects |> Enum.map(fn {_y, h} -> h end) |> Enum.sum() == Theme.height() - Theme.content_top()
    end
  end

  test "handle_key ignores everything, so Esc goes home" do
    for event <- [{:move, :up}, {:char, ?w}, {:nav, :home}] do
      assert Raycaster.handle_key(event, Raycaster.init()) == :ignore
    end
  end
end
