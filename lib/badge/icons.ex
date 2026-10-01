defmodule Badge.Icons do
  @moduledoc """
  Converted artwork from `assets/icons`, baked into the module at compile time.

  Files are named `<name>@<width>x<height>` with one of two suffixes. `.rgba`
  is straight-alpha `rgba8888` and is drawn as an image. `.mask` is one alpha
  byte per pixel for monochrome art; masks become glyphs in a uFont, one font
  per icon height, and are drawn as text, so AtomGL tints them in any colour.
  `Badge.UI` registers `fonts/0` at start.

  AtomGL blends every pixel that is not fully opaque against the background
  colour the item names, so an icon sits cleanly on any skin.

  Shapes are 32x32 and status icons are 16x16, so read `size/1` rather than
  assuming. Regenerate the files with `tools/icons.py`.
  """

  alias Badge.Theme

  @dir Path.expand("../../assets/icons", __DIR__)
  @shapes [:square, :triangle, :cross, :circle, :clover, :diamond]

  File.dir?(@dir) || raise "no icon directory at #{@dir} — run tools/icons.py"

  # The directory itself, so adding or removing an icon recompiles this module.
  # Per-file @external_resource cannot track a file that does not exist yet.
  @external_resource @dir

  @files Enum.sort(Path.wildcard(Path.join(@dir, "*.{rgba,mask}")))

  @files != [] || raise "no icon files in #{@dir} — run tools/icons.py"

  for file <- @files do
    @external_resource file
  end

  # Parsed and checked on the host, where the full standard library is available.
  @icons (for path <- @files, into: %{} do
            kind =
              case Path.extname(path) do
                ".rgba" -> :colour
                ".mask" -> :mask
              end

            base = Path.basename(path, Path.extname(path))

            # Host-only: the names come from a directory in this repo, not from input.
            {name, width, height} =
              case String.split(base, "@") do
                [name, dimensions] ->
                  case String.split(dimensions, "x") do
                    [width, height] ->
                      {String.to_atom(name), String.to_integer(width), String.to_integer(height)}

                    _ ->
                      raise "icon #{base}: expected <name>@<width>x<height>"
                  end

                _ ->
                  raise "icon #{base}: expected <name>@<width>x<height>"
              end

            data = File.read!(path)

            expected =
              case kind do
                :colour -> width * height * 4
                :mask -> width * height
              end

            byte_size(data) == expected ||
              raise "icon #{base}: #{byte_size(data)} bytes, expected #{expected}"

            {name, {width, height, kind, data}}
          end)

  # The Share art is one badge; the page draws it at twice size beside its half turn.
  @icons (case Map.get(@icons, :badge_share) do
            {width, height, :mask, mask} ->
              doubled =
                for y <- 0..(height - 1), _copy <- 1..2, into: <<>> do
                  for <<alpha <- :binary.part(mask, y * width, width)>>,
                    into: <<>>,
                    do: <<alpha, alpha>>
                end

              turned = doubled |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

              Map.merge(@icons, %{
                badge_share: {2 * width, 2 * height, :mask, doubled},
                badge_share_turned: {2 * width, 2 * height, :mask, turned}
              })

            nil ->
              @icons
          end)

  case @shapes -- Map.keys(@icons) do
    [] -> :ok
    missing -> raise "missing shape icons: #{Enum.join(missing, ", ")}"
  end

  @names Enum.sort(Map.keys(@icons))

  # uFont writing, for the attributes below.
  nibble = fn alpha, width, x, y ->
    if x < width, do: div(:binary.at(alpha, y * width + x) * 15 + 127, 255), else: 0
  end

  # Two pixels per byte, 4-bit alpha, the left pixel in the low nibble.
  pack = fn {width, height, alpha} ->
    for y <- 0..(height - 1),
        x <- 0..(width - 1)//2,
        into: <<>>,
        do: <<nibble.(alpha, width, x + 1, y)::4, nibble.(alpha, width, x, y)::4>>
  end

  # A glyph is the whole icon, its top-left at the item's origin.
  glyph = fn {width, height, _alpha}, offset ->
    <<width::little-16, height::little-16, width::little-16, 0::little-16, height::little-16,
      0::little-32, offset::little-32>>
  end

  add_glyph = fn mask, {glyphs, bitmap} ->
    {glyphs <> glyph.(mask, byte_size(bitmap)), bitmap <> pack.(mask)}
  end

  record = fn name, payload ->
    body = name <> <<byte_size(payload)::big-32>> <> payload
    body <> :binary.copy(<<0>>, rem(4 - rem(byte_size(body), 4), 4))
  end

  # The IFF layout ufontlib.c parses, with glyphs from "!" on.
  ufont = fn height, masks ->
    {glyphs, bitmap} = Enum.reduce(masks, {<<>>, <<>>}, add_glyph)
    header = <<1::little-32, 0, height::little-16, height::little-16, 0::little-16>>
    intervals = <<?!::little-32, ?! + length(masks) - 1::little-32, 0::little-32>>

    records =
      record.("uFH0", header) <>
        record.("uFP0", glyphs) <> record.("uFI0", intervals) <> record.("uFB0", bitmap)

    "FORM" <> <<byte_size(records) + 12::big-32>> <> "uFL0" <> records
  end

  @masks for {name, {width, height, :mask, alpha}} <- @icons,
             into: %{},
             do: {name, {width, height, alpha}}

  # One font per mask height, since a uFont has one ascender, as `{font, height, names}`.
  @by_font @masks
           |> Enum.group_by(fn {_name, {_width, height, _alpha}} -> height end, fn {name, _mask} ->
             name
           end)
           |> Enum.map(fn {height, names} -> {:"icons#{height}", height, Enum.sort(names)} end)

  @glyphs for {font, _height, names} <- @by_font,
              {name, index} <- Enum.with_index(names),
              into: %{},
              do: {name, {font, <<?! + index>>}}

  @fonts for {font, height, names} <- @by_font,
             into: %{},
             do: {font, ufont.(height, Enum.map(names, &@masks[&1]))}

  @doc "Every icon name, sorted."
  def names, do: @names

  @doc "The icon fonts as `{name, uFont binary}`, for `Badge.Display.register_font/3`."
  def fonts, do: Map.to_list(@fonts)

  @doc "Whether an icon is monochrome, and so takes a tint."
  def mono?(name), do: Map.has_key?(@glyphs, name)

  @doc "The raw `rgba8888` binary for a colour icon, or nil for a monochrome or unknown one."
  def binary(name)

  for {name, {_width, _height, :colour, data}} <- @icons do
    def binary(unquote(name)), do: unquote(data)
  end

  def binary(_name), do: nil

  @doc "The icon's `{width, height}` in pixels, or nil if there is no such icon."
  def size(name)

  for {name, {width, height, _kind, _data}} <- @icons do
    def size(unquote(name)), do: {unquote(width), unquote(height)}
  end

  def size(_name), do: nil

  @doc "A display item drawing `name` at native size in the skin's glyph colour on its background."
  def item(name, x, y), do: item(name, x, y, Theme.glyph(), Theme.bg())

  @doc "A display item drawing `name` at native size: a monochrome icon in `tint`, blended onto `bg`."
  def item(name, x, y, tint, bg)

  for {name, {font, text}} <- @glyphs do
    def item(unquote(name), x, y, tint, bg),
      do: {:text, x, y, unquote(font), tint, bg, unquote(text)}
  end

  def item(name, x, y, _tint, bg) do
    {width, height} = size(name)

    {:image, x, y, bg, {:rgba8888, width, height, binary(name)}}
  end
end
