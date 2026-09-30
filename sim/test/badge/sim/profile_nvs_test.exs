defmodule Badge.Sim.ProfileNvsTest do
  use ExUnit.Case, async: false

  alias Badge.Nvs
  alias Badge.Profile

  setup do
    start_supervised!(Badge.Sim.Nvs)
    :ok
  end

  test "a previously saved longer name loads within the new limit" do
    assert Nvs.put(:name, :binary.copy("x", 255)) == :ok
    assert Nvs.put(:company, "Protolux") == :ok

    profile = Profile.load()

    assert profile.name == :binary.copy("x", 64)
    assert profile.company == "Protolux"
    assert Profile.chat_name(profile) == :binary.copy("x", 16)
  end
end
