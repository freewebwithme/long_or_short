defmodule LongOrShort.Filings.SourceSupervisor do
  @moduledoc """
  Supervises the active filings source feeders.

  Children are configured statically via `:enabled_filing_sources`
  application config:

      config :long_or_short, enabled_filing_sources: [
        LongOrShort.Filings.Sources.SecEdgar
      ]

  Each entry must be a module implementing
  `LongOrShort.Filings.Source` (and being a GenServer). Entries
  are started as `{module, []}`, matching the
  `Filings.Sources.Pipeline.init/2` contract.

  Default is the empty list: until LON-112 wires the DB sink
  (`Filings.ingest_filing/1`) the feeders would only log and
  drop, so production stays disabled until that lands.

  Strategy is `:one_for_one`: a crash in one feeder doesn't take
  down siblings. Standard OTP restart policy applies.
  """

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl Supervisor
  def init(:ok) do
    sources = Application.get_env(:long_or_short, :enabled_filing_sources, [])
    children = Enum.map(sources, fn module -> {module, []} end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
