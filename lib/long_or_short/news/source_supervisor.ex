defmodule LongOrShort.News.SourceSupervisor do
  @moduledoc """
  Supervises the active news source feeders.

  Children are configured statically via `:enabled_news_sources`
  application config:

      config :long_or_short, enabled_news_sources: [
        LongOrShort.News.Sources.Dummy
      ]

  Each entry must be a module implementing `LongOrShort.News.Source`
  (and being a GenServer). Entries are started as `{module, []}`,
  matching the `Pipeline.init/2` contract that ignores opts when
  empty.

  Strategy is `:one_for_one`: a crash in one feeder doesn't take down
  the others. The default OTP restart policy applies — if a feeder
  crashes too many times in a short window, this supervisor itself
  will restart, which restarts all sibling feeders.
  """

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl Supervisor
  def init(:ok) do
    sources = Application.get_env(:long_or_short, :enabled_news_sources, [])
    children = Enum.map(sources, fn module -> {module, []} end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
