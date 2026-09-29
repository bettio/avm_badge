#!/usr/bin/env elixir
# Flashes badges as they are plugged in, several at once: each board gets a
# column that turns green or red once it has been written and seen to boot.
#
#     tools/flashstation.exs
#
# Needs Elixir, Erlang and a C compiler (see README.md: mise or asdf). Every other tool is
# installed on first run: through mise when it is on PATH, otherwise the way
# the README describes. Set BADGE_NH_KEY/BADGE_NH_SECRET or
# AVM_BADGE_SERVER_URL with ESP-IDF sourced to provision NVS as well.

# Consolidation is off so the script can implement Collectable for its own struct.
Mix.install(
  [{:breeze, "~> 0.5.3"}, {:muontrap, "~> 2.0"}],
  config: [back_breeze: [render_cache_max_memory_bytes: 64 * 1024 * 1024]],
  consolidate_protocols: false
)

defmodule Flashstation.Lines do
  @moduledoc false

  # A Collectable that turns command output into lines sent to `sink`.
  defstruct [:sink]

  defimpl Collectable do
    def into(%{sink: sink}) do
      collector = fn
        buffer, {:cont, data} -> emit(sink, buffer <> data)
        "", :done -> :ok
        buffer, :done -> send(sink, {:out, buffer})
        _buffer, :halt -> :ok
      end

      {"", collector}
    end

    # A carriage return ends a line too, so esptool's progress arrives one line at a time.
    defp emit(sink, data) do
      {complete, [rest]} = data |> String.split(["\r\n", "\n", "\r"]) |> Enum.split(-1)
      Enum.each(complete, &send(sink, {:out, &1}))
      rest
    end
  end
end

defmodule Flashstation.Shell do
  @moduledoc false

  @root Path.expand("..", __DIR__)
  @keep 40

  def root, do: @root

  @doc """
  Runs a command under muontrap, streaming each output line to `on_line`.

  Returns `{exit_status, tail}`, or `{:stopped, tail}` once `:until` matched a
  line, `{:timeout, tail}` after `:timeout` ms. Either way the child is dead.
  """
  def run(exe, args, on_line, opts \\ []) do
    caller = self()
    deadline = deadline(Keyword.get(opts, :timeout, :infinity))
    until = Keyword.get(opts, :until, fn _line -> false end)

    {pid, ref} =
      spawn_monitor(fn ->
        {_, status} =
          MuonTrap.cmd(exe, args,
            cd: @root,
            stderr_to_stdout: true,
            into: %Flashstation.Lines{sink: caller}
          )

        exit({:shutdown, {:status, status}})
      end)

    collect({pid, ref, exe}, on_line, until, deadline, [])
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp collect({pid, ref, exe} = child, on_line, until, deadline, tail) do
    receive do
      {:out, line} ->
        on_line.({kind(line), line})
        tail = Enum.take([line | tail], @keep)

        if until.(line) do
          stop(child)
          {:stopped, Enum.reverse(tail)}
        else
          collect(child, on_line, until, deadline, tail)
        end

      {:DOWN, ^ref, :process, ^pid, {:shutdown, {:status, status}}} ->
        {status, Enum.reverse(tail)}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        line = "could not run #{exe}: #{describe(reason)}"
        on_line.({:line, line})
        {:crashed, Enum.reverse([line | tail])}
    after
      remaining(deadline) ->
        stop(child)
        {:timeout, Enum.reverse(tail)}
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Killing the runner closes its port, and muontrap then kills the child.
  defp stop({pid, ref, _exe}) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> drain()
    end
  end

  defp drain do
    receive do
      {:out, _line} -> drain()
    after
      0 -> :ok
    end
  end

  defp describe({:enoent, _stack}), do: "not on PATH"
  defp describe({%{__exception__: true} = exception, _stack}), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason)

  # esptool prints one progress line per block when it is not on a tty.
  defp kind(line) do
    if line =~ ~r/^(Writing|Reading) .*\d%/, do: :progress, else: :line
  end

  def say(text), do: IO.puts("flashstation: " <> text)

  @doc "Runs a command in the plain terminal, exiting with a message when it fails."
  def run!(exe, args) do
    case run(exe, args, &echo/1) do
      {0, _tail} -> :ok
      {status, _tail} -> fail("#{exe} #{Enum.join(args, " ")} exited #{inspect(status)}")
    end
  end

  defp echo({:line, line}), do: IO.puts(line)
  defp echo({:progress, text}), do: IO.write("\r" <> text)

  def fail(message) do
    IO.puts(:stderr, "flashstation: " <> message)
    System.halt(1)
  end
end

defmodule Flashstation.Serial do
  @moduledoc false

  @patterns ["/dev/cu.usbmodem*", "/dev/ttyACM*"]

  @doc "Every badge on the serial bus, sorted by device path."
  def ports, do: @patterns |> Enum.flat_map(&Path.wildcard/1) |> Enum.sort()

  def stty_args(port) do
    flag = if match?({:unix, :darwin}, :os.type()), do: "-f", else: "-F"
    [flag, port, "115200", "raw", "-echo"]
  end
end

defmodule Flashstation.Setup do
  @moduledoc false

  alias Flashstation.Shell

  @provision_env ~w(BADGE_NH_KEY BADGE_NH_SECRET BADGE_NH_HOST BADGE_WIFI_SSID
                    BADGE_WIFI_PSK AVM_BADGE_SERVER_URL BADGE_UTC_OFFSET)

  # Offset and partition size of everything a badge is written, see README.md.
  @layout [
    {"bootloader.bin", 0x0, 0x8000},
    {"partition-table.bin", 0x8000, 0x1000},
    {"atomvm-esp32s3-badge.bin", 0x10000, 1920 * 1024},
    {"boot.avm", 0x1F0000, 544 * 1024},
    {"assets.avm", 0x278000, 256 * 1024},
    {"avm_badge.avm", 0x2B8000, 656 * 1024}
  ]
  @built ["assets.avm", "avm_badge.avm"]

  @doc "Installs what is missing and builds every artifact; returns the run options."
  def run do
    ensure_alone()
    Shell.say("checking tools")
    ensure_esptool()
    ensure_python()
    unless base_cached?(), do: ensure_gh()
    provision? = provisioning()

    Shell.say("fetching deps and building the firmware")
    Shell.run!("mix", ["deps.get"])
    Shell.run!("mix", ["atomvm.packbeam"])
    Shell.run!("mix", ["badge.assets"])
    Shell.run!("mix", ["badge.base", "--fetch-only"])
    %{provision?: provision?, images: images()}
  end

  # The esptool argument list: offset, file, offset, file...
  defp images do
    base = Path.join([Shell.root(), ".base", base_tag()])

    Enum.flat_map(@layout, fn {name, offset, size} ->
      dir = if name in @built, do: Shell.root(), else: base
      path = Path.join(dir, name)
      actual = File.stat!(path).size
      if actual < 128, do: Shell.fail("#{name} is only #{actual} bytes, looks truncated")
      if actual > size, do: Shell.fail("#{name} is #{actual} bytes, its partition holds #{size}")
      ["0x" <> Integer.to_string(offset, 16), path]
    end)
  end

  # Two stations would race each other's esptool for every port.
  defp ensure_alone do
    {out, _} = MuonTrap.cmd("pgrep", ["-f", "flashstation.exs"], stderr_to_stdout: true)
    others = out |> String.split() |> List.delete(System.pid())

    if others != [],
      do: Shell.fail("another flashstation is already running (pid #{Enum.join(others, ", ")})")
  end

  defp ensure_esptool do
    if esptool() do
      Shell.say("esptool found")
    else
      case installer() do
        :mise ->
          # mise's pypi backend installs through uv or pipx; a bare shim is not enough.
          unless mise_has?("uv") or mise_has?("pipx"), do: mise_use("uv")
          mise_use("pypi:esptool")

        :brew ->
          Shell.say("installing esptool with brew")
          Shell.run!("brew", ["install", "esptool"])

        :pipx ->
          Shell.say("installing esptool with pipx")
          Shell.run!("pipx", ["install", "esptool"])

        :pip ->
          Shell.say("installing esptool with pip")
          Shell.run!("python3", ["-m", "pip", "install", "--user", "esptool"])
      end

      unless esptool(), do: Shell.fail("esptool was installed but is still not on PATH")
    end
  end

  @doc "The esptool command as `{exe, leading args}`, under whichever name is installed."
  def esptool do
    cond do
      System.find_executable("esptool") -> {"esptool", []}
      System.find_executable("esptool.py") -> {"esptool.py", []}
      importable?() -> {"python3", ["-m", "esptool"]}
      true -> nil
    end
  end

  defp importable? do
    match?({_, 0}, MuonTrap.cmd("python3", ["-c", "import esptool"], stderr_to_stdout: true))
  end

  defp ensure_python do
    unless System.find_executable("python3"), do: Shell.fail("python3 is not on PATH")
  end

  defp base_tag, do: Shell.root() |> Path.join("BASE_IMAGE") |> File.read!() |> String.trim()

  defp base_cached? do
    dir = Path.join([Shell.root(), ".base", base_tag()])
    File.exists?(Path.join(dir, "SHA256SUMS")) and File.exists?(Path.join(dir, "boot.avm"))
  end

  defp ensure_gh do
    unless System.find_executable("gh") do
      case installer() do
        :mise ->
          mise_use("gh")

        :brew ->
          Shell.say("installing gh with brew")
          Shell.run!("brew", ["install", "gh"])

        _linux ->
          Shell.fail(
            "gh is needed to download the base image: " <>
              "https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
          )
      end
    end

    case MuonTrap.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
      {_, 0} -> Shell.say("gh is authenticated")
      _ -> Shell.fail("gh is not logged in; run `gh auth login` and start again")
    end
  end

  defp provisioning do
    wanted = Enum.filter(@provision_env, &System.get_env/1)

    cond do
      wanted == [] ->
        Shell.say("no BADGE_* settings in the environment, NVS will not be provisioned")
        false

      System.get_env("IDF_PATH") == nil ->
        Shell.fail(
          "#{Enum.join(wanted, ", ")} set but ESP-IDF is not sourced; " <>
            "run `. ~/esp/esp-idf/export.sh` or unset them"
        )

      "BADGE_WIFI_SSID" in wanted and "BADGE_WIFI_PSK" not in wanted ->
        Shell.fail("BADGE_WIFI_SSID needs BADGE_WIFI_PSK too, the tool cannot prompt here")

      true ->
        Shell.say("will provision #{Enum.join(wanted, ", ")}")
        true
    end
  end

  defp installer do
    cond do
      System.find_executable("mise") -> :mise
      System.find_executable("brew") -> :brew
      System.find_executable("pipx") -> :pipx
      true -> :pip
    end
  end

  defp mise_has?(name) do
    match?({_, 0}, MuonTrap.cmd("mise", ["which", name], stderr_to_stdout: true))
  end

  # This process has to put the new binary on its own PATH; the shell hook cannot.
  defp mise_use(tool) do
    Shell.say("installing #{tool} with mise")
    Shell.run!("mise", ["use", "-g", tool])
    name = tool |> String.split(":") |> List.last()

    case MuonTrap.cmd("mise", ["which", name], stderr_to_stdout: true) do
      {path, 0} ->
        dir = path |> String.trim() |> Path.dirname()
        System.put_env("PATH", dir <> ":" <> System.get_env("PATH", ""))

      {out, _} ->
        Shell.fail("mise installed #{tool} but cannot find it: #{String.trim(out)}")
    end
  end
end

defmodule Flashstation.Flash do
  @moduledoc false

  alias Flashstation.{Serial, Setup, Shell}

  @boot_timeout 30_000

  def steps(%{provision?: true}), do: ["Flash", "Provision", "Boot"]
  def steps(_config), do: ["Flash", "Boot"]

  @doc "Flashes the badge on `port`, reporting to `owner`; meant for `spawn_monitor`."
  def run(owner, port, config) do
    on_line = fn event -> send(owner, {:flash, port, event}) end

    result =
      Enum.reduce_while(steps(config), :ok, fn step, :ok ->
        send(owner, {:flash, port, {:step, step}})

        case step(step, port, config, on_line) do
          :ok -> {:cont, :ok}
          {:error, detail} -> {:halt, {:error, step, detail}}
        end
      end)

    send(owner, {:flash, port, {:done, result}})
  end

  defp step("Flash", port, config, on_line) do
    {exe, lead} = Setup.esptool()
    connect = ["--chip", "esp32s3", "--port", port, "--baud", "921600", "write_flash"]
    cmd(exe, lead ++ connect ++ config.images, on_line)
  end

  defp step("Provision", port, _config, on_line) do
    cmd("python3", ["tools/provision.py", "--port", port], on_line)
  end

  defp step("Boot", port, _config, on_line), do: boot(port, on_line)

  defp cmd(exe, args, on_line) do
    case Shell.run(exe, args, on_line) do
      {0, _tail} -> :ok
      {status, _tail} -> {:error, "#{exe} exited #{inspect(status)}"}
    end
  end

  # Opening the port resets the badge, so the whole boot log follows.
  defp boot(port, on_line) do
    with :ok <- await_port(port, 20), :ok <- configure(port), do: read_boot(port, on_line)
  end

  # The hard reset after a write re-enumerates the port for a moment.
  defp await_port(port, 0), do: {:error, "#{port} did not come back after the reset"}

  defp await_port(port, tries) do
    if File.exists?(port) do
      :ok
    else
      Process.sleep(250)
      await_port(port, tries - 1)
    end
  end

  defp configure(port) do
    case MuonTrap.cmd("stty", Serial.stty_args(port), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, "stty: #{String.trim(out)}"}
    end
  end

  defp read_boot(port, on_line) do
    case Shell.run("cat", [port], on_line, timeout: @boot_timeout, until: &decisive?/1) do
      {:stopped, tail} ->
        if Enum.any?(tail, &String.contains?(&1, "Badge: starting")),
          do: :ok,
          else: {:error, "the VM rejected boot.avm"}

      {:timeout, _tail} ->
        {:error, "no `Badge: starting` within #{div(@boot_timeout, 1000)}s"}

      {status, _tail} ->
        {:error, "the serial port closed while waiting for the boot log (#{inspect(status)})"}
    end
  end

  defp decisive?(line) do
    String.contains?(line, "Badge: starting") or String.contains?(line, "Invalid startup avmpack")
  end
end

defmodule Flashstation.View do
  @moduledoc false

  use Breeze.View
  import Breeze.Blocks

  @poll_ms 500
  @settle 2
  @linger 6

  @ok [
    " ██████  ██   ██ ",
    "██    ██ ██  ██  ",
    "██    ██ ██ ██   ",
    "██    ██ █████   ",
    "██    ██ ██ ██   ",
    "██    ██ ██  ██  ",
    " ██████  ██   ██ "
  ]

  @fail [
    "███████  █████  ██ ██      ",
    "██      ██   ██ ██ ██      ",
    "█████   ███████ ██ ██      ",
    "██      ██   ██ ██ ██      ",
    "██      ██   ██ ██ ███████ "
  ]

  def mount(opts, term) do
    send(self(), :poll)

    {:ok,
     term
     |> assign(config: Keyword.fetch!(opts, :config), boards: %{}, seen: %{})
     |> put_local_keybindings([{"r", "Retry"}])}
  end

  def handle_info(:poll, term) do
    Process.send_after(self(), :poll, @poll_ms)
    present = Flashstation.Serial.ports()
    {:noreply, term |> arrivals(present) |> departures(present)}
  end

  def handle_info({:flash, port, event}, term) do
    case term.assigns.boards[port] do
      nil -> {:noreply, term}
      board -> {:noreply, put_board(term, port, update(board, event))}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, term) when reason != :normal do
    case Enum.find(term.assigns.boards, fn {_port, board} -> board.worker == pid end) do
      {port, board} ->
        {:noreply, put_board(term, port, verdict(board, "flasher crashed: #{inspect(reason)}"))}

      nil ->
        {:noreply, term}
    end
  end

  def handle_info(_message, term), do: {:noreply, term}

  def handle_event(:input, %{"key" => "r"}, term) do
    boards =
      Map.new(term.assigns.boards, fn
        {port, %{state: :running} = board} -> {port, board}
        {port, _board} -> {port, start(port, term.assigns.config)}
      end)

    {:noreply, assign(term, boards: boards)}
  end

  def handle_event(_name, _event, term), do: {:noreply, term}

  # A port counts once seen on consecutive polls; the board re-enumerates around resets.
  defp arrivals(term, present) do
    seen = Map.new(present, fn port -> {port, (term.assigns.seen[port] || 0) + 1} end)

    boards =
      Enum.reduce(seen, term.assigns.boards, fn {port, count}, boards ->
        if count >= @settle and not Map.has_key?(boards, port),
          do: Map.put(boards, port, start(port, term.assigns.config)),
          else: boards
      end)

    assign(term, seen: seen, boards: boards)
  end

  defp departures(term, present) do
    boards =
      term.assigns.boards
      |> Enum.map(fn {port, board} ->
        {port, %{board | gone: if(port in present, do: 0, else: board.gone + 1)}}
      end)
      |> Enum.reject(fn {_port, board} -> board.state != :running and board.gone >= @linger end)
      |> Map.new()

    assign(term, boards: boards)
  end

  defp start(port, config) do
    owner = self()
    {pid, _ref} = spawn_monitor(fn -> Flashstation.Flash.run(owner, port, config) end)

    %{
      state: :running,
      worker: pid,
      steps: Flashstation.Flash.steps(config),
      step: nil,
      done: [],
      lines: [],
      error: nil,
      gone: 0
    }
  end

  defp update(board, {:step, step}) do
    done = if board.step, do: [board.step | board.done], else: []
    %{board | step: step, done: done, lines: []}
  end

  defp update(board, {:line, line}), do: %{board | lines: [{:line, line} | board.lines]}

  defp update(board, {:progress, text}) do
    case board.lines do
      [{:progress, _} | rest] -> %{board | lines: [{:progress, text} | rest]}
      rest -> %{board | lines: [{:progress, text} | rest]}
    end
  end

  defp update(board, {:done, :ok}), do: %{board | state: :ok, worker: nil, gone: 0}
  defp update(board, {:done, {:error, step, detail}}), do: verdict(board, "#{step}: #{detail}")

  defp verdict(board, error), do: %{board | state: :failed, error: error, worker: nil, gone: 0}

  defp put_board(term, port, board) do
    assign(term, boards: Map.put(term.assigns.boards, port, board))
  end

  def render(assigns) do
    ports = assigns.boards |> Map.keys() |> Enum.sort()
    columns = max(length(ports), 1)
    height = assigns.breeze.terminal.height - 1

    assigns =
      assign(assigns,
        ports: ports,
        columns: columns,
        width: div(assigns.breeze.terminal.width, columns),
        height: height,
        top: max(div(height - 1, 2), 0)
      )

    ~H"""
    <box class="w-screen h-screen">
      <box :if={@ports == []} class={"w-full pt-#{@top}"}>
        <box class="w-full text-center font-bold">Plug in a badge</box>
      </box>
      <box :if={@ports != []} class={"grid grid-cols-#{@columns} w-full h-#{@height}"}>
        <.board
          :for={port <- @ports}
          port={port}
          board={@boards[port]}
          width={@width}
          height={@height}
        />
      </box>
      <box class={"absolute top-#{@height} left-0 w-full h-1 overflow-hidden"}>
        <.keybinding_bar keybindings={@breeze.keybindings} />
      </box>
    </box>
    """
  end

  attr(:port, :string, required: true)
  attr(:board, :map, required: true)
  attr(:width, :integer, required: true)
  attr(:height, :integer, required: true)

  defp board(%{board: %{state: :running}} = assigns) do
    room = assigns.height - length(assigns.board.steps) - 3
    assigns = assign(assigns, tail: tail(assigns.board, room))

    ~H"""
    <box class={"h-#{@height} overflow-hidden"}>
      <box class="font-bold">{Path.basename(@port)}</box>
      <box :for={step <- @board.steps} class={step_class(step, @board)}>
        {marker(step, @board)} {step}
      </box>
      <box class="h-1"></box>
      <box :for={{_kind, line} <- @tail} class="text-muted overflow-hidden h-1">{line}</box>
    </box>
    """
  end

  defp board(%{board: %{state: :ok}} = assigns) do
    art = art(@ok, "OK", assigns.width)
    assigns = assign(assigns, art: art, top: centre(assigns.height, length(art) + 2))

    ~H"""
    <box class={"h-#{@height} bg-34 text-231 overflow-hidden"}>
      <box class={"w-full pt-#{@top}"}>
        <box :for={row <- @art} class="w-full text-center font-bold">{row}</box>
        <box class="h-1"></box>
        <box class="w-full text-center">{Path.basename(@port)}: unplug it</box>
      </box>
    </box>
    """
  end

  defp board(%{board: %{state: :failed}} = assigns) do
    art = art(@fail, "FAIL", assigns.width)
    tail = tail(assigns.board, 10)
    top = centre(assigns.height, length(art) + 5 + length(tail))
    assigns = assign(assigns, art: art, tail: tail, top: top)

    ~H"""
    <box class={"h-#{@height} bg-196 text-231 overflow-hidden"}>
      <box class={"w-full pt-#{@top}"}>
        <box :for={row <- @art} class="w-full text-center font-bold">{row}</box>
        <box class="h-1"></box>
        <box class="w-full text-center font-bold">{@board.error}</box>
        <box class="w-full text-center">{Path.basename(@port)}: unplug it, or press r to retry</box>
        <box class="h-1"></box>
      </box>
      <box :for={{_kind, line} <- @tail} class="overflow-hidden h-1 pl-2">{line}</box>
    </box>
    """
  end

  # Block letters need room; a narrow column gets plain text instead.
  defp art(rows, word, width) do
    if width >= String.length(hd(rows)) + 2, do: rows, else: [word]
  end

  defp centre(height, rows), do: max(div(height - rows, 2), 0)

  defp tail(board, room), do: board.lines |> Enum.take(max(room, 3)) |> Enum.reverse()

  defp marker(step, %{step: step}), do: "▶"
  defp marker(step, board), do: if(step in board.done, do: "✓", else: "·")

  defp step_class(step, %{step: step}), do: "font-bold"
  defp step_class(step, board), do: if(step in board.done, do: "text-success", else: "text-muted")
end

defmodule Flashstation do
  @moduledoc false

  def main do
    config = Flashstation.Setup.run()
    Process.flag(:trap_exit, true)

    {:ok, session} =
      Breeze.Server.start_link(
        view: Flashstation.View,
        start_opts: [config: config],
        logger: :replace,
        global_keybindings: [{"q", "Quit", fn _event, term -> {:stop, term} end}]
      )

    ref = Process.monitor(session)

    receive do
      {:DOWN, ^ref, :process, ^session, _reason} -> :ok
    end
  end
end

Flashstation.main()
