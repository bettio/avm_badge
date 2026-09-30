defmodule Badge.IconsTest do
  use ExUnit.Case, async: true

  alias Badge.Icons
  alias Badge.Sim.Font
  alias Badge.Skin
  alias Badge.Theme

  @shapes [:circle, :clover, :cross, :diamond, :square, :triangle]
  @status [
    :battery_0,
    :battery_100,
    :battery_25,
    :battery_50,
    :battery_75,
    :battery_charging,
    :messages,
    :wifi,
    :wifi_slash,
    :email,
    :github,
    :linkedin,
    :mastodon,
    :bluesky,
    :company,
    :link,
    :signal_0,
    :signal_1,
    :signal_2,
    :signal_3
  ]

  @art [:badge_share, :badge_share_turned]

  @dir Path.expand("../../assets/icons", __DIR__)

  # The Share pair is derived from one 43x28 source: doubled, and doubled then turned.
  defp mask(:badge_share) do
    source = File.read!(Path.join(@dir, "badge_share@43x28.mask"))

    for y <- 0..27, _copy <- 1..2, into: <<>> do
      for <<a <- :binary.part(source, y * 43, 43)>>, into: <<>>, do: <<a, a>>
    end
  end

  defp mask(:badge_share_turned),
    do: mask(:badge_share) |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp mask(name) do
    {w, h} = Icons.size(name)
    File.read!(Path.join(@dir, "#{name}@#{w}x#{h}.mask"))
  end

  defp glyph(name) do
    {:text, 0, 0, font, _fg, _bg, <<cp>>} = Icons.item(name, 0, 0)
    fonts = Map.new(Icons.fonts())

    {Font.parse(Map.fetch!(fonts, font)), Font.glyph(Font.parse(Map.fetch!(fonts, font)), cp)}
  end

  describe "names/0" do
    test "is sorted" do
      assert Icons.names() == :lists.sort(Icons.names())
    end

    test "holds every shape and every status icon" do
      assert Icons.names() == :lists.sort(@shapes ++ @status ++ @art)
    end
  end

  describe "mono?/1" do
    test "status icons are monochrome and shapes are not" do
      for name <- @status ++ @art, do: assert(Icons.mono?(name))
      for name <- @shapes, do: refute(Icons.mono?(name))
    end

    test "an unknown name is false rather than a crash" do
      refute Icons.mono?(:nonesuch)
    end
  end

  describe "size/1" do
    test "shapes are 32x32 and status icons 16x16" do
      for name <- @shapes, do: assert(Icons.size(name) == {32, 32})
      for name <- @status, do: assert(Icons.size(name) == {16, 16})
    end

    test "an unknown name is nil rather than a crash" do
      assert Icons.size(:nonesuch) == nil
    end
  end

  describe "binary/1" do
    test "a colour icon is w * h * 4 bytes, and not grey" do
      for name <- @shapes do
        {w, h} = Icons.size(name)
        binary = Icons.binary(name)
        hued = for <<r, g, b, 0xFF <- binary>>, r != g or g != b, do: :hued

        assert byte_size(binary) == w * h * 4
        assert hued != []
      end
    end

    test "a monochrome or unknown icon has none" do
      assert Icons.binary(:wifi) == nil
      assert Icons.binary(:nonesuch) == nil
    end
  end

  describe "fonts/0" do
    test "one font per mask height" do
      assert Enum.sort(Keyword.keys(Icons.fonts())) == [:icons16, :icons56]
    end

    test "a glyph is its mask at 4 bits, with the top-left on the item's origin" do
      for name <- @status ++ @art do
        {font, glyph} = glyph(name)
        {w, h} = Icons.size(name)

        assert {glyph.width, glyph.height, glyph.advance, glyph.left, glyph.top} ==
                 {w, h, w, 0, h}

        assert {font.ascender, font.descender} == {h, 0}

        levels = for y <- 0..(h - 1), x <- 0..(w - 1), do: Font.level(glyph, x, y)
        expected = for <<a <- mask(name)>>, do: div(a * 15 + 127, 255)

        assert levels == expected
      end
    end

    test "every glyph has a visible body" do
      for name <- @status ++ @art do
        {_font, glyph} = glyph(name)
        {w, h} = Icons.size(name)
        levels = for y <- 0..(h - 1), x <- 0..(w - 1), do: Font.level(glyph, x, y)

        assert Enum.max(levels) >= 4
      end
    end
  end

  describe "the Share pair" do
    # Their pixels are checked against the doubled and turned source by the glyph test above.
    test "is one badge at twice size, and the same turned 180 degrees" do
      assert Icons.size(:badge_share) == {86, 56}
      assert Icons.size(:badge_share_turned) == {86, 56}
    end
  end

  describe "item/3" do
    test "a monochrome icon is a glyph in the skin's glyph colour on its background" do
      assert {:text, 10, 20, :icons16, fg, bg, <<_cp>>} = Icons.item(:wifi, 10, 20)

      assert {fg, bg} == {Theme.glyph(), Theme.bg()}
    end

    test "follows the active skin" do
      Skin.activate(Badge.Skin.Win95)

      assert {:text, 0, 0, :icons16, fg, bg, _glyph} = Icons.item(:wifi, 0, 0)
      assert {fg, bg} == {Badge.Skin.Win95.glyph(), Badge.Skin.Win95.bg()}
    end

    test "a colour icon is an image at native size" do
      assert {:image, 0, 0, _bg, {:rgba8888, 32, 32, binary}} = Icons.item(:square, 0, 0)
      assert binary == Icons.binary(:square)
    end

    test "every icon draws something different" do
      items = for name <- Icons.names(), do: Icons.item(name, 0, 0, 0xFFFFFF, 0)

      assert length(:lists.usort(items)) == length(items)
    end
  end

  describe "item/5" do
    test "takes any tint and an explicit background" do
      assert {:text, 1, 2, :icons16, 0x123456, 0x000080, _glyph} =
               Icons.item(:wifi, 1, 2, 0x123456, 0x000080)
    end
  end
end
