defmodule LongOrShort.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ingest health observability (LON-161) — create the ETS counter
    # table and attach the boot telemetry handler before any SEC EDGAR
    # feeder starts, so the very first CIK drop after boot is counted.
    LongOrShort.Filings.IngestHealth.init()
    LongOrShort.Filings.IngestHealth.attach_telemetry_handler()

    children =
      [
        LongOrShortWeb.Telemetry,
        LongOrShort.Repo,
        # Boot hydration (LON-125) — read admin-tunable settings rows
        # into Application env BEFORE any worker that consumes them
        # starts. Sits between Repo (which it needs for DB read) and
        # Oban (whose workers may read settings on their first run).
        # See `LongOrShort.Settings.Loader` for the failure-mode
        # contract.
        LongOrShort.Settings.Loader,
        {DNSCluster, query: Application.get_env(:long_or_short, :dns_cluster_query) || :ignore},
        {Oban,
         AshOban.config(
           Application.fetch_env!(:long_or_short, :ash_domains),
           Application.fetch_env!(:long_or_short, Oban)
         )},
        {Phoenix.PubSub, name: LongOrShort.PubSub},
        LongOrShort.News.Dedup,
        LongOrShort.News.SourceSupervisor,
        LongOrShort.Filings.SourceSupervisor,
        {Task.Supervisor, name: LongOrShort.Analysis.TaskSupervisor},
        # Start to serve requests, typically the last entry
        LongOrShortWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :long_or_short]}
      ] ++ maybe_price_stream() ++ maybe_indices_poller()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LongOrShort.Supervisor]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LongOrShortWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_price_stream do
    if Application.get_env(:long_or_short, :enable_price_stream, true) do
      [LongOrShort.Tickers.Sources.FinnhubStream]
    else
      []
    end
  end

  defp maybe_indices_poller do
    if Application.get_env(:long_or_short, :enable_indices_poller, true) do
      [LongOrShort.Tickers.Sources.IndicesPoller]
    else
      []
    end
  end
end
