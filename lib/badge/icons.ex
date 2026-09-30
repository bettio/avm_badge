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

  # Each mask height gets its own font, since a uFont has one ascender; glyphs start at "!".
  @glyphs (for {height, names} <-
                 Enum.group_by(
                   for({name, {_w, h, :mask, _data}} <- @icons, do: {name, h}),
                   &elem(&1, 1),
                   &elem(&1, 0)
                 ),
               {name, index} <- Enum.with_index(Enum.sort(names)),
               into: %{} do
             {name, {:"icons#{height}", <<0x21 + index>>}}
           end)

  # A uFont as ufontlib.c parses it: a glyph is its icon, 4-bit alpha, with the top-left at the item's origin.
  @fonts (for {font, entries} <- Enum.group_by(@glyphs, fn {_name, {font, _text}} -> font end),
              into: %{} do
            names =
              Enum.sort_by(entries, fn {_name, {_font, text}} -> text end)
              |> Enum.map(&elem(&1, 0))

            {_w, height, :mask, _data} = @icons[hd(names)]

            {glyphs, bitmap} =
              Enum.reduce(names, {<<>>, <<>>}, fn name, {glyphs, bitmap} ->
                {width, ^height, :mask, mask} = @icons[name]
                nibble = fn x, y -> div(:binary.at(mask, y * width + x) * 15 + 127, 255) end

                packed =
                  for y <- 0..(height - 1), x <- 0..(width - 1)//2, into: <<>> do
                    high = if x + 1 < width, do: nibble.(x + 1, y), else: 0
                    <<high::4, nibble.(x, y)::4>>
                  end

                glyph =
                  <<width::little-16, height::little-16, width::little-16, 0::little-16,
                    height::little-16, 0::little-32, byte_size(bitmap)::little-32>>

                {glyphs <> glyph, bitmap <> packed}
              end)

            record = fn name, payload ->
              body = name <> <<byte_size(payload)::big-32>> <> payload
              body <> :binary.copy(<<0>>, rem(4 - rem(byte_size(body), 4), 4))
            end

            records =
              record.(
                "uFH0",
                <<1::little-32, 0, height::little-16, height::little-16, 0::little-16>>
              ) <>
                record.("uFP0", glyphs) <>
                record.(
                  "uFI0",
                  <<0x21::little-32, 0x20 + length(names)::little-32, 0::little-32>>
                ) <>
                record.("uFB0", bitmap)

            {font, "FORM" <> <<byte_size(records) + 12::big-32>> <> "uFL0" <> records}
          end)

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
