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
    # Restore the original :enabled_news_sources after each test.
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

  test "sends :poll to every enabled news source GenServer" do
    {:ok, _pid} = FakeFeeder.start_link(self())
    Application.put_env(:long_or_short, :enabled_news_sources, [FakeFeeder])

    assert :ok = MorningBoundaryPollWorker.perform(%Oban.Job{args: %{}})
    assert_receive {:fake_feeder_polled, FakeFeeder}, 500
  end

  test "skips silently when the source GenServer is not running" do
    # No FakeFeeder started — Process.whereis(FakeFeeder) is nil.
    Application.put_env(:long_or_short, :enabled_news_sources, [FakeFeeder])

    assert :ok = MorningBoundaryPollWorker.perform(%Oban.Job{args: %{}})
  end

  test "no-op when :enabled_news_sources is empty" do
    Application.put_env(:long_or_short, :enabled_news_sources, [])
    assert :ok = MorningBoundaryPollWorker.perform(%Oban.Job{args: %{}})
  end
end
