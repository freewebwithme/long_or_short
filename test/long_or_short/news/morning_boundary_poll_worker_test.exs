defmodule LongOrShort.News.MorningBoundaryPollWorkerTest do
  use ExUnit.Case, async: false

  alias LongOrShort.News.MorningBoundaryPollWorker

  # A throwaway GenServer that records every `:poll` message it
  # receives. Used here as a stand-in for the real Alpaca / Finnhub
  # / SecEdgar feeder GenServers so we can assert the worker
  # actually delivers the message without spinning up real feeders.
  defmodule FakeFeeder do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: __MODULE__)

    @impl true
    def init(parent), do: {:ok, %{parent: parent}}

    @impl true
    def handle_info(:poll, %{parent: parent} = state) do
      send(parent, {:fake_feeder_polled, __MODULE__})
      {:noreply, state}
    end
  end

  setup do
    prior = Application.get_env(:long_or_short, :enabled_news_sources)

    on_exit(fn ->
      if is_nil(prior) do
        Application.delete_env(:long_or_short, :enabled_news_sources)
      else
        Application.put_env(:long_or_short, :enabled_news_sources, prior)
      end
    end)

    :ok
  end

  # UTC timestamps mapping to specific ET times. May (EDT, UTC-4):
  #   07:00 ET = 11:00 UTC, 07:30 ET = 11:30 UTC, ..., 10:30 ET = 14:30 UTC
  # 2026-05-11 is a Monday.
  @at_07_00_et ~U[2026-05-11 11:00:00Z]
  @at_07_30_et ~U[2026-05-11 11:30:00Z]
  @at_10_30_et ~U[2026-05-11 14:30:00Z]

  # Non-boundary slots within Mon–Fri.
  @at_06_30_et ~U[2026-05-11 10:30:00Z]
  @at_11_00_et ~U[2026-05-11 15:00:00Z]

  # Saturday at 09:00 ET.
  @at_sat_09_00_et ~U[2026-05-16 13:00:00Z]

  describe "tick/1 inside the ET morning window (Mon–Fri)" do
    setup do
      {:ok, _pid} = FakeFeeder.start_link(self())
      Application.put_env(:long_or_short, :enabled_news_sources, [FakeFeeder])
      :ok
    end

    test "07:00 ET dispatches :poll" do
      assert :ok = MorningBoundaryPollWorker.tick(@at_07_00_et)
      assert_receive {:fake_feeder_polled, FakeFeeder}, 500
    end

    test "07:30 ET dispatches :poll" do
      assert :ok = MorningBoundaryPollWorker.tick(@at_07_30_et)
      assert_receive {:fake_feeder_polled, FakeFeeder}, 500
    end

    test "10:30 ET dispatches :poll (upper boundary)" do
      assert :ok = MorningBoundaryPollWorker.tick(@at_10_30_et)
      assert_receive {:fake_feeder_polled, FakeFeeder}, 500
    end
  end

  describe "tick/1 outside the boundary" do
    setup do
      {:ok, _pid} = FakeFeeder.start_link(self())
      Application.put_env(:long_or_short, :enabled_news_sources, [FakeFeeder])
      :ok
    end

    test "06:30 ET (before window) does NOT dispatch" do
      assert :ok = MorningBoundaryPollWorker.tick(@at_06_30_et)
      refute_receive {:fake_feeder_polled, _}, 100
    end

    test "11:00 ET (after window) does NOT dispatch" do
      assert :ok = MorningBoundaryPollWorker.tick(@at_11_00_et)
      refute_receive {:fake_feeder_polled, _}, 100
    end

    test "Saturday 09:00 ET does NOT dispatch" do
      assert :ok = MorningBoundaryPollWorker.tick(@at_sat_09_00_et)
      refute_receive {:fake_feeder_polled, _}, 100
    end
  end

  describe "dispatch edge cases" do
    test "skips silently when the source GenServer is not running" do
      Application.put_env(:long_or_short, :enabled_news_sources, [FakeFeeder])
      assert :ok = MorningBoundaryPollWorker.tick(@at_07_00_et)
    end

    test "no-op when :enabled_news_sources is empty" do
      Application.put_env(:long_or_short, :enabled_news_sources, [])
      assert :ok = MorningBoundaryPollWorker.tick(@at_07_00_et)
    end
  end

  describe "perform/1 (Oban entry point)" do
    test "delegates to tick/1 with current UTC time" do
      Application.put_env(:long_or_short, :enabled_news_sources, [])
      assert :ok = MorningBoundaryPollWorker.perform(%Oban.Job{args: %{}})
    end
  end
end
