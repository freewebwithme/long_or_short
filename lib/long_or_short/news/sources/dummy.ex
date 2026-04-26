defmodule LongOrShort.News.Sources.Dummy do
  @moduledoc """
  In-memory news source for development and end-to-end pipeline
  validation. Cycles through a fixed set of sample articles, each
  with a counter-based `external_id` so Dedup treats every cycle
  as a new article.

  Enabled in `dev` only via `:enabled_news_sources` config; not
  started in `test` or `prod`. Once real sources (Benzinga, SEC,
  PR Newswire) land, this module can be kept around for offline
  demos or removed entirely.
  """

  use GenServer
  @behaviour LongOrShort.News.Source

  alias LongOrShort.News.Sources.Pipeline

  # ── GenServer setup ────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts), do: Pipeline.init(__MODULE__, opts)

  @impl GenServer
  def handle_info(:poll, state), do: Pipeline.run_poll(__MODULE__, state)

  # ── News.Source callbacks ──────────────────────────────────────
  @impl LongOrShort.News.Source
  def poll_interval_ms, do: 3_000

  @impl LongOrShort.News.Source
  def fetch_news(state) do
    counter = Map.get(state, :counter, 0)
    sample = Enum.at(samples(), rem(counter, length(samples())))
    raw = Map.put(sample, :external_id, "dummy-#{counter}")
    new_state = Map.put(state, :counter, counter + 1)
    {:ok, [raw], new_state}
  end

  @impl LongOrShort.News.Source
  def parse_response(raw) do
    attrs = %{
      source: :other,
      external_id: raw.external_id,
      symbol: raw.symbol,
      title: raw.title,
      summary: raw.summary,
      published_at: DateTime.utc_now(),
      raw_category: "General",
      sentiment: :unknown
    }

    {:ok, [attrs]}
  end

  # ── Sample data ────────────────────────────────────────────────

  defp samples do
    [
      %{
        symbol: "BTBD",
        title: "BTBD announces new strategic partnership",
        summary: "Bit Brother subsidiary signs deal in defense sector."
      },
      %{
        symbol: "AAPL",
        title: "Apple beats Q2 earnings expectations",
        summary: "Services revenue hits all-time high."
      },
      %{
        symbol: "TSLA",
        title: "Tesla quarterly deliveries up 15% YoY",
        summary: "Production ramp continues in Berlin and Austin."
      },
      %{
        symbol: "NVDA",
        title: "Nvidia unveils next-generation AI chip",
        summary: "New architecture targets datacenter inference workloads."
      },
      %{
        symbol: "AMD",
        title: "AMD partners with major cloud provider",
        summary: "Multi-year supply agreement for EPYC processors."
      }
    ]
  end
end
