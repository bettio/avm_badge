defmodule Mix.Tasks.Badge.Assets do
  @shortdoc "Packs assets.avm from the frames, fonts and logo the device reads at runtime"

  @moduledoc """
  Writes `assets.avm` at the repo root and, with `--flash`, writes it to the
  assets partition.

      mix badge.assets
      mix badge.assets --flash
  """

  use Mix.Task

  @out "assets.avm"
  @offset 0x278000
  @size 262_144
  @min 10_240

  @impl Mix.Task
  def run(args) do
    {options, _rest} = OptionParser.parse!(args, strict: [flash: :boolean])
    pack()
    if options[:flash], do: flash()
  end

  defp flash do
    out = Path.expand(@out)
    size = File.stat!(out).size

    cond do
      size < @min -> Mix.raise("#{@out} is only #{size}B, looks empty or truncated")
      size > @size -> Mix.raise("#{@out} is #{size}B, partition holds #{@size}B")
      true -> Mix.shell().info("#{@out}: #{size}B of #{@size}B")
    end

    Mix.Tasks.Badge.Base.write_flash([{@offset, out}])
    Mix.shell().info("#{@out} written, the badge has reset")
  end

  defp pack do
    stage = Path.join(System.tmp_dir!(), "badge-assets-#{System.unique_integer([:positive])}")
    rickroll = Path.join(stage, "assets/priv/rickroll")
    fonts = Path.join(stage, "assets/priv/fonts")
    logo = Path.join(stage, "assets/priv/logo")

    try do
      File.mkdir_p!(rickroll)
      File.mkdir_p!(fonts)
      File.mkdir_p!(logo)
      frames = Path.wildcard("assets/rickroll/*.rgba")
      uf_fonts = Path.wildcard("assets/fonts/*.uf")
      logos = Path.wildcard("assets/logo/*.rgba")
      if frames == [], do: Mix.raise("no frames found in assets/rickroll")
      if uf_fonts == [], do: Mix.raise("no fonts found in assets/fonts")
      if logos == [], do: Mix.raise("no logo found in assets/logo")
      copy(frames, rickroll)
      copy(uf_fonts, fonts)
      copy(logos, logo)

      out = Path.expand(@out)
      # Names inside the archive are relative to the staging directory.
      File.cd!(stage, fn ->
        inputs =
          (Path.wildcard("assets/priv/rickroll/*.rgba") ++
             Path.wildcard("assets/priv/fonts/*.uf") ++
             Path.wildcard("assets/priv/logo/*.rgba"))
          |> Enum.map(&to_charlist/1)

        :ok = :packbeam_api.create(to_charlist(out), inputs, %{lib: true})
      end)

      Mix.shell().info("#{@out}: #{File.stat!(out).size} bytes")
    after
      File.rm_rf!(stage)
    end
  end

  defp copy(paths, dest) do
    for path <- paths, do: File.cp!(path, Path.join(dest, Path.basename(path)))
  end
end
