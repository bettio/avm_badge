defmodule Badge.Skin.WinXP do
  @moduledoc """
  Luna: a beige client area under a blue caption with rounded corners and
  a red close button.

  The caption is a banded gradient, light at the top and dark at the foot,
  with a flat middle band that the title, clock and icons sit on. Page
  colours are the Luna set: royal blue accent, green, amber and red.
  """

  @behaviour Badge.Skin

  alias Badge.Icons
  alias Badge.Theme

  @white 0xFFFFFF
  @black 0x000000
  @beige 0xECE9D8
  @band 0x0A5DE8
  @red 0xD44B31

  # Gradient rows above and below the flat band, top to bottom.
  @top_rows [0x0A3EB5, 0x5B9BFF, 0x2C7BF7]
  @band_y length(@top_rows)
  @band_h 17
  @foot_y @band_y + @band_h
  @foot_rows [0x0450CE, 0x02379E]

  @caption for {colour, i} <- Enum.with_index(@top_rows),
               do: {:rect, 0, i, Theme.width(), 1, colour}
  @caption @caption ++ [{:rect, 0, @band_y, Theme.width(), @band_h, @band}]
  @caption @caption ++
             for(
               {colour, i} <- Enum.with_index(@foot_rows),
               do: {:rect, 0, @foot_y + i, Theme.width(), 1, colour}
             )

  # The caption's top corners rounded off against the client colour, a row at a time.
  @corners for {w, y} <- Enum.with_index([3, 2, 1]),
               side <- [0, Theme.width() - w],
               do: {:rect, side, y, w, 1, @beige}

  @text_y 3
  @text_x 8
  @char_w 8

  # The close button is a white outline round a red face, inset from the right.
  @button_w 18
  @button_h 16
  @button_x Theme.width() - 4 - @button_w
  @button_y @band_y

  @status_gap 6
  @status_w elem(Icons.size(:battery_100), 0)
  @battery_x @button_x - @status_gap - @status_w
  @wifi_x @battery_x - @status_gap - @status_w

  @impl true
  def name, do: "WinXP"

  @impl true
  def bg, do: @beige
  @impl true
  def fg, do: @black
  @impl true
  def muted, do: 0x505050
  @impl true
  def dim, do: 0xACA899
  @impl true
  def accent, do: 0x0054E3
  @impl true
  def ok, do: 0x3C9F3C
  @impl true
  def warn, do: 0xCC8400
  @impl true
  def alert, do: 0xC81E14
  @impl true
  def select, do: 0x316AC5
  @impl true
  def glyph, do: @black

  # Caption icons are white on the band, like the title beside them.
  @impl true
  def chrome(title, status) do
    [
      Icons.item(status.battery, @battery_x, @text_y, @white, @band),
      Icons.item(status.wifi, @wifi_x, @text_y, @white, @band),
      clock_item(status.clock),
      {:text, @text_x, @text_y, :pixel_operator, @white, @band, title}
    ] ++
      close_button() ++
      @corners ++
      @caption ++
      [{:rect, 0, 0, Theme.width(), Theme.height(), @beige}]
  end

  # Etched: a shadow row over a highlight row, as round a group box.
  @impl true
  def rule(x, y, w) do
    [{:rect, x, y, w, 1, 0xD0CFBF}, {:rect, x, y + 1, w, 1, @white}]
  end

  defp clock_item(clock) do
    x = div(Theme.width() - @char_w * byte_size(clock), 2)

    {:text, x, @text_y, :default16px, @white, @band, clock}
  end

  # A white outline round a red face, its corners blunted, with an x in the middle.
  defp close_button do
    right = @button_x + @button_w - 1
    bottom = @button_y + @button_h - 1

    [
      {:text, @button_x + div(@button_w - @char_w, 2), @button_y, :default16px, @white, @red,
       "x"},
      {:rect, @button_x, @button_y, 1, 1, @band},
      {:rect, right, @button_y, 1, 1, @band},
      {:rect, @button_x, bottom, 1, 1, @band},
      {:rect, right, bottom, 1, 1, @band},
      {:rect, @button_x + 1, @button_y + 1, @button_w - 2, @button_h - 2, @red},
      {:rect, @button_x, @button_y, @button_w, @button_h, @white}
    ]
  end
end
