defmodule LongOrShort.SettingsTest do
  @moduledoc """
  Unit tests for the `LongOrShort.Settings` domain helpers
  (`get/1`, `get!/2`) — LON-125.

  These are intentionally thin wrappers over `Application.get_env`,
  so the tests are equally thin. The substantive behaviour (DB →
  Application env) lives in `LongOrShort.Settings.LoaderTest`.
  """

  use ExUnit.Case, async: false

  alias LongOrShort.Settings

  # Use a key that we know is referenced as an atom somewhere in the
  # codebase but does not have a config default — keeps the tests
  # independent of config.exs values that may shift over time.
  @test_key :__settings_helper_test_key__

  setup do
    # Reset our test key between cases.
    Application.delete_env(:long_or_short, @test_key)
    on_exit(fn -> Application.delete_env(:long_or_short, @test_key) end)
    :ok
  end

  describe "fetch/1" do
    test "returns {:ok, value} when the key is set" do
      Application.put_env(:long_or_short, @test_key, 42)
      assert Settings.fetch(@test_key) == {:ok, 42}
    end

    test "returns :error when the key is missing" do
      assert Settings.fetch(@test_key) == :error
    end

    test "accepts any term as a value (passes through Application env)" do
      Application.put_env(:long_or_short, @test_key, %{nested: "map"})
      assert Settings.fetch(@test_key) == {:ok, %{nested: "map"}}
    end
  end

  describe "get/2" do
    test "returns the value when the key is set" do
      Application.put_env(:long_or_short, @test_key, "hello")
      assert Settings.get(@test_key, "default") == "hello"
    end

    test "returns the default when the key is missing" do
      assert Settings.get(@test_key, "default") == "default"
    end

    test "default can be any term, including nil" do
      assert Settings.get(@test_key, nil) == nil
      assert Settings.get(@test_key, %{x: 1}) == %{x: 1}
    end
  end
end
