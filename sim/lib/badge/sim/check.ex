defmodule Badge.Sim.Check do
  @moduledoc "Renders every page through the shared UI, without a browser."

  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Sim.Board
  alias Badge.Sim.Display

  @doc "The splash, then every page on the home grid's first screen."
  def pages,
    do: [Splash] ++ for({_key, module} <- Badge.Pages.screen(0), module != nil, do: module)

  @doc "Renders `page` through `Badge.UI` and returns its complete display snapshot."
  def render(page) do
    snapshot = show(page)
    {:ok, snapshot.items, snapshot.frame, snapshot.assets}
  rescue
    error -> {:error, error}
  end

  @doc "Writes the frame of every page to `dir` as JSON, for a renderer to check offline."
  def dump(dir) do
    File.mkdir_p!(dir)

    for page <- pages() do
      {:ok, _items, frame, assets} = render(page)
      name = page |> inspect() |> String.replace(".", "_")
      File.write!(Path.join(dir, name <> ".json"), JSON.encode!(%{items: frame, assets: assets}))
    end

    :ok
  end

  defp show(Splash) do
    case current_page() do
      Splash -> :ok
      _other -> Board.reboot()
    end

    %{page: Splash} = :sys.get_state(Badge.UI)
    Display.snapshot()
  end

  defp show(page) do
    case current_page() do
      ^page ->
        Display.snapshot()

      _other ->
        navigate(page)
    end
  end

  defp navigate(page) do
    go_home()
    key = key_for(page)
    Badge.UI.key_event({:nav, key})
    state = await_page(page, 50)

    with true <- state.dirty,
         sequence = Display.snapshot().sequence,
         :render_tick <- send(Badge.UI, :render_tick),
         {:ok, snapshot} <- Display.await_frame(sequence) do
      snapshot
    else
      false -> Display.snapshot()
      {:error, :timeout} -> raise "timed out rendering #{inspect(page)}"
    end
  end

  # The home grid opens a page from its own tick, so the key is not the arrival.
  defp await_page(page, 0),
    do: raise("#{inspect(page)} never opened, still on #{inspect(:sys.get_state(Badge.UI).page)}")

  defp await_page(page, tries) do
    case :sys.get_state(Badge.UI) do
      %{page: ^page} = state ->
        state

      _other ->
        Process.sleep(20)
        await_page(page, tries - 1)
    end
  end

  # Only the home grid opens pages. The splash takes any key as its cue to end, and hands over on the next tick.
  defp go_home do
    case current_page() do
      Home ->
        :ok

      Splash ->
        Badge.UI.key_event({:nav, :home})
        send(Badge.UI, :render_tick)
        %{page: Home} = :sys.get_state(Badge.UI)

      _page ->
        Badge.UI.key_event({:nav, :home})
        %{page: Home} = :sys.get_state(Badge.UI)
    end
  end

  defp current_page, do: :sys.get_state(Badge.UI).page

  defp key_for(page) do
    case :lists.keyfind(page, 2, Badge.Pages.screen(0)) do
      {key, ^page} -> key
      false -> raise "#{inspect(page)} is not a top-level page"
    end
  end
end
