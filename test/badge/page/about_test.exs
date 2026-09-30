defmodule Badge.Page.AboutTest do
  use ExUnit.Case, async: true

  alias Badge.Font
  alias Badge.Page.About
  alias Badge.QR
  alias Badge.Theme

  @margin 8

  defp state(index) do
    {:ok, code} = QR.encode("https://github.com/protolux-electronics/avm_badge")
    %{index: index, ref: make_ref(), pid: nil, qr: {:ok, code}}
  end

  defp body(index) do
    for {:text, x, y, font, _fg, _bg, text} <- About.render(state(index)),
        y > Theme.content_top(),
        font != :icons16,
        do: {x, y, font, text}
  end

  defp strings(index), do: for({_x, _y, _font, text} <- body(index), do: text)

  test "the tabs run badge, getting started, credits" do
    titles =
      for {:text, _x, y, _f, _fg, _bg, text} <- About.render(state(0)),
          y == Theme.content_top(),
          do: text

    assert titles == ["Badge", "Getting started", "Credits"]
  end

  test "right and left turn through the tabs, wrapping" do
    {:ok, next} = About.handle_key({:move, :right}, state(2))
    assert next.index == 0

    {:ok, previous} = About.handle_key({:move, :left}, state(0))
    assert previous.index == 2
  end

  test "the badge tab has no part numbers" do
    text = Enum.join(strings(0), " ")

    assert text =~ "Goatmire"
    assert text =~ "ESP32-S3"
    assert text =~ "AtomVM"
    refute text =~ "SK6812"
    refute text =~ "ST7789"
  end

  test "getting started shows the code and the repository" do
    items = About.render(state(1))

    assert Enum.any?(items, &(elem(&1, 0) == :scaled_cropped_image))
    assert "protolux-electronics/avm_badge" in strings(1)
  end

  test "credits thank the contributors and the assembly helpers" do
    text = Enum.join(strings(2), " ")

    assert hd(strings(2)) == "Brought to you by"

    names = for {x, _y, _font, text} <- body(2), text == "Gus Workman", do: x
    assert names == [@margin + 16]
    assert text =~ "Gus Workman"
    assert text =~ "sent in code"
    assert text =~ "assemble"
  end

  test "every line of every tab fits inside the margins" do
    for index <- 0..2, {x, y, font, text} <- body(index) do
      assert x >= @margin, "#{inspect(text)} starts left of the margin"
      assert x + Font.width(font, text) <= Theme.width() - @margin, "#{inspect(text)} runs off"
      assert y + 16 <= Theme.height(), "#{inspect(text)} runs off the bottom"
    end
  end
end
