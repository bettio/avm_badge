defmodule Raycaster.Engine do
  @moduledoc """
  A small Wolfenstein-style raycaster, in integers only.

  AtomVM has no fast floats on this chip, so positions are Q8 fixed point (256
  is one map cell), angles are 65536 to a turn, and sine comes from a table
  built while compiling on the laptop. `frame/4` turns a player into a display
  list of rectangles, one per run of equal wall columns.

  The map is not read from this module while rendering: see `grid/0`.
  """

  import Bitwise

  # Vertical slices across the screen. Ray casting is nearly all of the frame
  # time and costs the same per slice, so this is the frame rate knob: 80 slices
  # ran at 7 fps on the badge standing still, 40 at 12-13 (about 10 while
  # walking). It must divide the screen width.
  @cols 40
  @half div(@cols, 2)
  # Distance along a ray that never crosses a grid line. AtomVM's integers are
  # 28 bits wide on this chip before they spill onto the heap, so keep it
  # below 2^27.
  @far 1 <<< 26

  # 16 x 16. Digits are wall types, `.` is floor. The outer ring must be wall:
  # rays are not bounds checked and stop only when they enter a wall cell.
  @rows [
    "3333333333333333",
    "3..............3",
    "3..1111....22..3",
    "3..1..........23",
    "3..1..........23",
    "3..1......11...3",
    "3.......2..1...3",
    "3.......2..1...3",
    "3..22...2......3",
    "3..............3",
    "3....1111......3",
    "3....1..1..22..3",
    "3....1..1..2...3",
    "3...........2..3",
    "3..............3",
    "3333333333333333"
  ]

  @size length(@rows)

  # One flat tuple, row after row. AtomVM copies a module literal onto the heap
  # every time it is used, and this one is 256 words: looked up per grid step
  # that ran the badge out of memory. So it is fetched once with grid/0 and
  # handed down as an argument, which passes a pointer instead.
  @grid @rows
        |> Enum.flat_map(fn row ->
          row
          |> String.to_charlist()
          |> Enum.map(fn
            ?. -> 0
            char -> char - ?0
          end)
        end)
        |> List.to_tuple()

  @ceiling 0x202838
  @floor 0x504030

  # Q8 per second, and angle units per second.
  @move_speed 800
  @turn_speed 40_000
  # A bit for each direction a key can ask for, see keys/2.
  @forward 1
  @back 2
  @right 4
  @left 8
  @turn_right 16
  @turn_left 32

  # How close to a wall the player may get, in Q8.
  @radius 60

  # Pasted into columns/4 by the compiler, saving a call per column.
  @compile {:inline, colour: 3, rgb: 1}

  def new, do: %{x: 384, y: 384, a: 0}

  # The map. Call this once and pass the result to step/4 and frame/4.
  def grid, do: @grid

  def cols, do: @cols

  # Held keys are labels from Raycaster.Keymap, binaries or charlists.
  def step(grid, state, held, dt_ms) do
    keys = keys(held, 0)
    forward = axis(keys, @forward, @back)
    strafe = axis(keys, @right, @left)
    turn = axis(keys, @turn_right, @turn_left)

    angle = state.a + div(turn * @turn_speed * dt_ms, 1000)
    index = index(angle)
    dir_x = cos(index)
    dir_y = sin(index)

    distance = div(@move_speed * dt_ms, 1000)
    dx = div((dir_x * forward - dir_y * strafe) * distance, 256)
    dy = div((dir_y * forward + dir_x * strafe) * distance, 256)

    # Each axis on its own, so a wall is slid along instead of stopping dead.
    x =
      if open?(grid, state.x + dx + sign(dx) * @radius, state.y), do: state.x + dx, else: state.x

    y = if open?(grid, x, state.y + dy + sign(dy) * @radius), do: state.y + dy, else: state.y

    %{state | x: x, y: y, a: angle}
  end

  def frame(grid, %{x: x, y: y, a: angle}, width, height) do
    index = index(angle)
    dir_x = cos(index)
    dir_y = sin(index)
    # The camera plane is perpendicular to the direction, 0.66 as long: about a
    # 66 degree field of view.
    plane_x = div(-dir_y * 169, 256)
    plane_y = div(dir_x * 169, 256)
    column_width = div(width, @cols)

    # Every ray starts from the same cell, so where the player stands is worked
    # out once here. The cell is its place in the grid tuple, counted from 1 as
    # :erlang.element/2 does (elem/2 counts from 0 and adds the 1 on every
    # read), and in_x, in_y are how far into that cell the player is.
    cell = (y >>> 8) * @size + (x >>> 8) + 1
    in_x = x &&& 255
    in_y = y &&& 255

    # What every column needs and none changes, in one tuple: a call only has
    # to keep a few variables alive across it, and each one costs a save and a
    # restore on this chip.
    view = {grid, cell, in_x, in_y, dir_x, dir_y, plane_x, plane_y, column_width, height}

    # The first item is on top, so floor and ceiling go last, behind the walls.
    # The walls are put in front of them as they are found.
    behind = [
      {:rect, 0, div(height, 2), width, height - div(height, 2), @floor},
      {:rect, 0, 0, width, div(height, 2), @ceiling}
    ]

    # AtomVM runs a scheduler on each of the chip's two cores, so the right
    # half of the screen is cast in a second process while this one casts the
    # left. It goes from the right edge towards the middle, so both halves end
    # with their open rectangle at the seam, where join/3 puts the two back
    # together if they turn out to be one.
    parent = self()
    ref = make_ref()

    spawn_link(fn ->
      send(parent, {ref, columns(view, @cols - 1, @half - 1, -1, nil, [])})
    end)

    {left_run, left} = columns(view, 0, @half, 1, nil, behind)

    receive do
      # The right half's rectangles come nearest the seam first; the display
      # list wants the rightmost first.
      {^ref, {right_run, right}} -> :lists.reverse(right, join(left_run, right_run, left))
    end
  end

  # `run` is the rectangle being widened: neighbouring columns with the same
  # height and colour (a flat wall facing you) become one rectangle. Casts
  # columns from `i` up to or down to `stop` (by `step`, +1 or -1), and returns
  # the rectangle still being widened along with the finished ones before it.
  defp columns(_view, stop, stop, _step, run, acc), do: {run, acc}

  defp columns(view, i, stop, step, run, acc) do
    {grid, cell, in_x, in_y, dir_x, dir_y, plane_x, plane_y, column_width, height} = view

    camera = div(2 * i * 256, @cols) - 256
    ray_x = dir_x + div(plane_x * camera, 256)
    ray_y = dir_y + div(plane_y * camera, 256)

    {wall, side, dist} = cast(grid, cell, in_x, in_y, ray_x, ray_y)
    line = min(div(height * 256, max(dist, 1)), height)
    top = div(height - line, 2)
    colour = colour(wall, side, dist)

    {run, acc} =
      case run do
        {rx, rw, ^top, ^line, ^colour} ->
          # Going leftwards, the rectangle grows at its left edge.
          x = if step > 0, do: rx, else: i * column_width
          {{x, rw + column_width, top, line, colour}, acc}

        _ ->
          {{i * column_width, column_width, top, line, colour}, emit(run, acc)}
      end

    columns(view, i + step, stop, step, run, acc)
  end

  # The two rectangles meeting at the seam, one from each half: one rectangle
  # if they match, as a single pass across the screen would have made it.
  defp join({x, w, top, line, colour}, {_x, right_w, top, line, colour}, acc),
    do: [{:rect, x, top, w + right_w, line, colour} | acc]

  defp join(left_run, right_run, acc), do: emit(right_run, emit(left_run, acc))

  defp emit(nil, acc), do: acc
  defp emit({x, w, y, h, colour}, acc), do: [{:rect, x, y, w, h, colour} | acc]

  # Digital differential analysis: hop from grid line to grid line along the
  # ray until a wall cell is entered. Returns {wall type, side hit, distance}.
  #
  # Per axis: delta is how far along the ray one whole cell is, and side how
  # far the first grid line is (the rest of the cell, as a fraction of a whole
  # one, times delta). A ray that never crosses that axis's lines gets @far for
  # both. Written as plain ifs rather than a helper returning a tuple, which
  # cost a call and a tuple for each axis of each ray.
  defp cast(grid, cell, in_x, in_y, ray_x, ray_y) do
    delta_x = if ray_x == 0, do: @far, else: div(65_536, abs(ray_x))
    delta_y = if ray_y == 0, do: @far, else: div(65_536, abs(ray_y))

    side_x =
      cond do
        ray_x < 0 -> div(in_x * delta_x, 256)
        ray_x == 0 -> @far
        true -> div((256 - in_x) * delta_x, 256)
      end

    side_y =
      cond do
        ray_y < 0 -> div(in_y * delta_y, 256)
        ray_y == 0 -> @far
        true -> div((256 - in_y) * delta_y, 256)
      end

    # A step across a vertical grid line moves one place in the grid tuple,
    # across a horizontal one a whole row.
    step_x = if ray_x < 0, do: -1, else: 1
    step_y = if ray_y < 0, do: -@size, else: @size

    march(grid, cell, side_x, side_y, delta_x, delta_y, step_x, step_y)
  end

  # The inner loop, run for every grid line every ray crosses. Kept to a
  # comparison, two additions and a tuple read per step: 6 BEAM instructions,
  # where it was about 37 with the bounds checked cell/3 call and a step
  # counter. There is no bounds check and no step limit, because the map's
  # outer wall stops every ray.
  defp march(grid, cell, side_x, side_y, delta_x, delta_y, step_x, step_y) do
    if side_x < side_y do
      cell = cell + step_x

      case :erlang.element(cell, grid) do
        0 -> march(grid, cell, side_x + delta_x, side_y, delta_x, delta_y, step_x, step_y)
        wall -> {wall, 0, side_x}
      end
    else
      cell = cell + step_y

      case :erlang.element(cell, grid) do
        0 -> march(grid, cell, side_x, side_y + delta_y, delta_x, delta_y, step_x, step_y)
        wall -> {wall, 1, side_y}
      end
    end
  end

  defp cell(_grid, x, y) when x < 0 or y < 0 or x >= @size or y >= @size, do: 1
  defp cell(grid, x, y), do: elem(grid, y * @size + x)

  defp open?(grid, x, y), do: cell(grid, x >>> 8, y >>> 8) == 0

  # Darker with distance, and walls facing along y a little darker again, so
  # corners read.
  defp colour(wall, side, dist) do
    rgb = rgb(wall)
    r = rgb >>> 16
    g = rgb >>> 8 &&& 255
    b = rgb &&& 255
    shade = max(48, 256 - div(dist, 12))
    shade = if side == 1, do: div(shade * 3, 4), else: shade

    div(r * shade, 256) <<< 16 ||| div(g * shade, 256) <<< 8 ||| div(b * shade, 256)
  end

  # The held keys as one integer, a bit per direction, read in a single pass.
  # Matching the labels in function heads keeps them out of the module's
  # literals, which AtomVM would copy on every use: the lists of labels this
  # replaced cost 3 ms a frame on the badge.
  defp keys([], bits), do: bits
  defp keys([label | rest], bits), do: keys(rest, bits ||| key(label))

  defp key("Up"), do: @forward
  defp key("W"), do: @forward
  defp key("Down"), do: @back
  defp key("S"), do: @back
  defp key("E"), do: @right
  defp key("Q"), do: @left
  defp key("Right"), do: @turn_right
  defp key("D"), do: @turn_right
  defp key("Left"), do: @turn_left
  defp key("A"), do: @turn_left
  # The badge firmware's keyboard reports labels as charlists.
  defp key(~c"Up"), do: @forward
  defp key(~c"W"), do: @forward
  defp key(~c"Down"), do: @back
  defp key(~c"S"), do: @back
  defp key(~c"E"), do: @right
  defp key(~c"Q"), do: @left
  defp key(~c"Right"), do: @turn_right
  defp key(~c"D"), do: @turn_right
  defp key(~c"Left"), do: @turn_left
  defp key(~c"A"), do: @turn_left
  defp key(_label), do: 0

  # 1, 0 or -1: both directions of an axis held cancel out.
  defp axis(keys, plus, minus), do: held(keys, plus) - held(keys, minus)

  defp held(keys, bit) when (keys &&& bit) == 0, do: 0
  defp held(_keys, _bit), do: 1

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_n), do: 0

  # Wall colours by type. A function of plain integers rather than a tuple of
  # tuples, because AtomVM copies a module literal onto the heap on every use,
  # and this is read once per column.
  defp rgb(1), do: 0xC83C32
  defp rgb(2), do: 0x3CAA46
  defp rgb(3), do: 0x4664D2

  defp index(angle), do: angle >>> 8 &&& 255
  defp sin(index), do: sin_table(index)
  defp cos(index), do: sin_table(index + 64 &&& 255)

  # 256 steps to a turn, scaled by 256. One clause per step, built while
  # compiling, for the same reason as rgb/1: the compiler turns them into a
  # jump table of plain integers, where a tuple would be a literal.
  for step <- 0..255 do
    defp sin_table(unquote(step)),
      do: unquote(round(:math.sin(step * 2 * :math.pi() / 256) * 256))
  end
end
