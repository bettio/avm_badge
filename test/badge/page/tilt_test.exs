defmodule Badge.Page.TiltTest do
  use ExUnit.Case, async: true

  alias Badge.Accel
  alias Badge.Icons
  alias Badge.Page.Tilt
  alias Badge.Theme

  defp marker(state) do
    [{:image, x, y, _bg, _img} | _rest] = Tilt.render(state)

    {x, y}
  end

  defp levelled, do: at(0, 0)

  defp at(roll, pitch), do: Tilt.update(Tilt.init(), {roll, pitch})

  # The page for raw sensor registers, in counts at 16384 per g.
  defp sensed(x, y, z) do
    bytes = <<x::little-signed-16, y::little-signed-16, z::little-signed-16>>

    Tilt.update(Tilt.init(), Accel.orientation(Accel.decode(bytes)))
  end

  defp marker_size, do: Icons.size(:circle)

  describe "identity" do
    test "names itself for the carousel" do
      assert Tilt.title() == "Tilt"
    end

    test "repaints slowly, since a frame is a whole panel" do
      assert Tilt.refresh(Tilt.init()) == 333
    end
  end

  describe "levelling against gravity" do
    test "a badge lying face up sits at the centre, with nothing pressed" do
      assert sensed(0, 0, -16384) == levelled()
    end

    test "tipping the top edge away moves the marker up, not sideways" do
      {x, y} = marker(sensed(0, -8192, -14189))
      {cx, cy} = marker(levelled())

      assert x == cx
      assert y < cy
    end

    test "lowering the right edge moves the marker right, not up or down" do
      {x, y} = marker(sensed(8192, 0, -14189))
      {cx, cy} = marker(levelled())

      assert x > cx
      assert y == cy
    end

    test "the very first reading is already measured, not swallowed as a zero" do
      refute marker(at(30, 0)) == marker(levelled())
    end

    test "no key is claimed, so a container owns them all" do
      for event <- [{:char, ?a}, {:move, :up}, {:move, :left}, {:move, :right}, {:edit, :newline}] do
        assert Tilt.handle_key(event, Tilt.init()) == :ignore
      end
    end
  end

  describe "update/2" do
    test "level sits at the centre of the plot" do
      {w, h} = marker_size()
      {x, y} = marker(levelled())

      assert x == 160 - div(w, 2)
      assert y == 120 - div(h, 2)
    end

    test "roll moves the marker horizontally, toward the lowered edge" do
      {positive, _y} = marker(at(45, 0))
      {centre, _y2} = marker(at(0, 0))
      {negative, _y3} = marker(at(-45, 0))

      assert negative < centre
      assert centre < positive
    end

    test "the readout agrees with the direction the marker moved" do
      [body] = for {:text, _x, _y, _f, _fg, _bg, body} <- Tilt.render(at(30, 0)), do: body
      {x, _y} = marker(at(30, 0))

      # Marker right of centre means a positive roll on screen.
      assert x > elem(marker(at(0, 0)), 0)
      assert :binary.match(body, "roll 30") != :nomatch
    end

    test "pitching moves the marker vertically" do
      {_x, up} = marker(at(0, -45))
      {_x2, centre} = marker(at(0, 0))
      {_x3, down} = marker(at(0, 45))

      assert up < centre
      assert centre < down
    end

    test "the marker moves further the more it is tilted" do
      centre = elem(marker(at(0, 0)), 0)
      small = abs(elem(marker(at(10, 0)), 0) - centre)
      medium = abs(elem(marker(at(25, 0)), 0) - centre)
      large = abs(elem(marker(at(40, 0)), 0) - centre)

      assert small < medium
      assert medium < large
    end

    test "past the clamp the marker stops moving" do
      assert marker(at(45, 0)) == marker(at(90, 0))
      assert marker(at(-45, 0)) == marker(at(-120, 0))
      assert marker(at(0, 80)) == marker(at(0, 45))
    end

    test "position is quantised so noise does not repaint" do
      {x, y} = marker(at(37, 23))

      assert rem(x, 8) == 0
      assert rem(y, 8) == 0
    end

    test "a degree of wobble either way leaves the marker alone" do
      centre = marker(levelled())

      # Half a quantum is about 1.3 degrees, so that is the deadzone.
      for wobble <- [-1, 0, 1] do
        assert marker(at(wobble, wobble)) == centre
      end
    end

    test "a sub-quantum wobble does not change state" do
      assert at(1, 0) == at(0, 0)
    end

    test "a real movement does change state" do
      refute at(0, 0) == at(30, 0)
    end

    test "equal readings give equal state, so the router stays clean" do
      assert at(12, -8) == at(12, -8)
    end
  end

  describe "render/1" do
    test "the marker is the first item, so it draws over the readout" do
      [first | _rest] = Tilt.render(levelled())

      assert {:image, _x, _y, _bg, {:rgba8888, _w, _h, _bin}} = first
    end

    test "shows both angles" do
      texts = for {:text, _x, _y, _f, _fg, _bg, body} <- Tilt.render(at(-30, -20)), do: body

      assert length(texts) == 1
      assert :binary.match(hd(texts), "roll -30") != :nomatch
      assert :binary.match(hd(texts), "pitch -20") != :nomatch
    end

    test "a perfectly level reading reads exactly zero" do
      [body] = for {:text, _x, _y, _f, _fg, _bg, body} <- Tilt.render(levelled()), do: body

      assert :binary.match(body, "roll 0") != :nomatch
      assert :binary.match(body, "pitch 0") != :nomatch
    end

    test "no longer tells anyone to press Enter" do
      [body] = for {:text, _x, _y, _f, _fg, _bg, body} <- Tilt.render(levelled()), do: body

      assert :binary.match(body, "Enter") == :nomatch
    end

    test "the readout fits the panel" do
      [body] = for {:text, _x, _y, _f, _fg, _bg, body} <- Tilt.render(at(-44, -44)), do: body

      assert 4 + 8 * byte_size(body) <= Theme.width()
    end

    test "the marker stays on the panel at every extreme" do
      {w, h} = marker_size()

      for roll <- [-90, -45, 0, 45, 90], pitch <- [-90, -45, 0, 45, 90] do
        {x, y} = marker(at(roll, pitch))

        assert x >= 0
        assert x + w <= Theme.width()
        assert y >= Theme.content_top()
        assert y + h <= Theme.height()
      end
    end

    test "the marker never overlaps the readout" do
      {_w, h} = marker_size()

      for roll <- [-45, 0, 45], pitch <- [-45, 0, 45] do
        {_x, y} = marker(at(roll, pitch))

        assert y + h <= 218
      end
    end

    test "emits no background rect" do
      refute Enum.any?(Tilt.render(levelled()), fn
               {:rect, 0, 0, 320, 240, _colour} -> true
               _item -> false
             end)
    end
  end
end
