defmodule Badge.Page.Raycaster do
  @moduledoc """
  A Wolfenstein-style 3D view of a small map, drawn by `Raycaster.Engine`.

  Arrows or W A S D move and turn, Q and E strafe, Esc leaves. The keys are
  read as held rather than tapped, with `Badge.Keyboard.held/0` on every tick:
  key events only arrive on press and auto-repeat, which is no way to walk.

  A frame is about 60 to 110 ms of ray casting, so the page asks for the
  shortest gap the ticker offers and lives with about 10 frames a second.
  Standing still returns the same state, so nothing is cast or drawn.

  The map is fetched with `Raycaster.Engine.grid/0` once per call and never
  kept in the state: AtomVM copies a module literal onto the heap each time it
  is looked up, so the lookup must not be in a per-ray loop, and a term that
  size does not belong in the state `Badge.UI` holds either.
  """

  use Badge.Page

  alias Badge.Keyboard
  alias Badge.Theme
  alias Raycaster.Engine

  # The view fills what is under the title bar.
  @view_w Theme.width()
  @view_h Theme.height() - Theme.content_top()

  # The most one step may move, so a long stall does not fling the player
  # through a wall in a single go. The engine's own clamp is per axis.
  @max_dt 250

  @impl true
  def title, do: "Raycaster"

  @impl true
  def icon, do: :clover

  @impl true
  def refresh(_state), do: 100

  # `at` is when the player last moved, or nil while standing still, so that a
  # standing player is the same state tick after tick and nothing is redrawn.
  @impl true
  def init, do: %{player: Engine.new(), at: nil}

  @impl true
  def tick(%{player: player, at: at} = state) do
    case Keyboard.held() do
      [] ->
        %{state | at: nil}

      held ->
        now = now()
        dt = if at == nil, do: 100, else: min(now - at, @max_dt)

        %{state | player: Engine.step(Engine.grid(), player, held, dt), at: now}
    end
  end

  @impl true
  def render(%{player: player}) do
    Engine.frame(Engine.grid(), player, @view_w, @view_h)
    |> shift(Theme.content_top(), [])
  end

  # The engine draws from y = 0; the title bar takes the top of the panel.
  defp shift([], _top, acc), do: :lists.reverse(acc)

  defp shift([{:rect, x, y, w, h, colour} | rest], top, acc) do
    shift(rest, top, [{:rect, x, y + top, w, h, colour} | acc])
  end

  defp now, do: :erlang.monotonic_time(:millisecond)
end
