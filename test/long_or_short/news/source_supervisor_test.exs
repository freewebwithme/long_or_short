defmodule LongOrShort.News.SourceSupervisorTest do
  @moduledoc """
  Tests for the supervisor that brings up enabled news sources.

  Strategy: each test temporarily overrides :enabled_news_sources
  config, starts a fresh supervisor with start_supervised!, and
  verifies the resulting child structure. The on_exit hook restores
  the original config so tests don't leak.
  """
  use ExUnit.Case, async: false

  alias LongOrShort.News.Dedup
  alias LongOrShort.News.SourceSupervisor
  alias LongOrShort.News.Sources.Dummy

  setup do
    original = Application.get_env(:long_or_short, :enabled_news_sources)

    on_exit(fn ->
      if original do
        Application.put_env(:long_or_short, :enabled_news_sources, original)
      else
        Application.delete_env(:long_or_short, :enabled_news_sources)
      end
    end)

    Dedup.clear()
    :ok
  end

  describe "init/1" do
    test "starts each module in :enabled_news_sources as a child" do
      Application.put_env(:long_or_short, :enabled_news_sources, [Dummy])

      pid = start_supervised!({SourceSupervisor, [name: :test_source_sup]})

      children = Supervisor.which_children(pid)
      assert length(children) == 1

      [{module, child_pid, type, _}] = children
      assert module == Dummy
      assert is_pid(child_pid)
      assert Process.alive?(child_pid)
      assert type == :worker
    end

    test "starts cleanly with empty source list" do
      Application.put_env(:long_or_short, :enabled_news_sources, [])

      pid = start_supervised!({SourceSupervisor, [name: :test_source_sup]})

      assert Supervisor.which_children(pid) == []
    end

    test "starts cleanly when config key is missing entirely" do
      Application.delete_env(:long_or_short, :enabled_news_sources)

      pid = start_supervised!({SourceSupervisor, [name: :test_source_sup]})

      assert Supervisor.which_children(pid) == []
    end
  end
end
