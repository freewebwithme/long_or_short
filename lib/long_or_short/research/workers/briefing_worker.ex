defmodule LongOrShort.Research.Workers.BriefingWorker do
  @moduledoc """
  Async path for on-demand Pre-Trade Briefing (LON-172).

  The Generator (`Research.BriefingGenerator.generate/3`) is synchronous
  and takes 8–25s on a cache miss (web_search + Sonnet round-trip).
  Blocking a LiveView for that long is bad UX, so the LiveView (PT-2)
  enqueues this worker instead and listens for the PubSub callback
  from `LongOrShort.Research.Events`.

  Pattern mirrors LON-144 (`feed_live.ex` async analyzer dispatch):
  enqueue → spinner → `handle_info(:briefing_ready, ...)` → swap.

  ## Args contract

      %{
        "symbol" => "AAPL",
        "user_id" => "019e...",
        "request_id" => "01HX...",  # optional; auto-generated if omitted
        "opts" => %{                # optional Generator opts
          "model" => "...",
          "max_searches" => 3,
          "force" => true            # LON-174: bypass cache (rate-limited 1/60s)
        }
      }

  Returns Oban's standard `:ok | {:error, term} | :discard`. The
  PubSub broadcast is the primary "return value" — Oban's status is
  for retry/discard logic.

  ## Failure handling

  Generator returns `{:error, reason}` → worker broadcasts
  `:briefing_failed` and returns `{:error, reason}` to Oban. Oban
  retries by default (`max_attempts: 3`); after the cap the job is
  discarded but the trader has already seen the failure broadcast.

  Unrecoverable errors (`:unknown_symbol`, `:no_trading_profile`)
  return `{:discard, reason}` so we don't waste retry budget — these
  won't succeed on retry.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger

  alias LongOrShort.Accounts.User
  alias LongOrShort.Research.BriefingGenerator
  alias LongOrShort.Research.Events

  @doc """
  Enqueue an async briefing generation. Returns the
  `{request_id, %Oban.Job{}}` pair so the caller can correlate the
  job with the PubSub `:briefing_started | :ready | :failed`
  messages.

  ## Example

      iex> {request_id, _job} =
      ...>   BriefingWorker.enqueue("AAPL", current_user.id)
      iex> Research.Events.subscribe_for_user(current_user.id)
      iex> receive do
      ...>   {:briefing_started, _, ^request_id} -> :got_started
      ...> end
  """
  @spec enqueue(String.t(), Ecto.UUID.t(), keyword()) ::
          {String.t(), {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}}
  def enqueue(symbol, user_id, opts \\ []) do
    request_id = Keyword.get_lazy(opts, :request_id, &generate_request_id/0)
    generator_opts = Keyword.get(opts, :generator_opts, %{})

    job =
      %{
        "symbol" => symbol,
        "user_id" => user_id,
        "request_id" => request_id,
        "opts" => stringify_keys(generator_opts)
      }
      |> __MODULE__.new()
      |> Oban.insert()

    {request_id, job}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "symbol" => symbol,
      "user_id" => user_id,
      "request_id" => request_id
    } = args

    generator_opts = atomize_opts(args["opts"] || %{})

    # Broadcast start unconditionally — even if the user resolve
    # fails below, the LiveView spinner-state machine wants to know
    # the worker picked up the job (otherwise it would never time
    # out of "queued" state visually).
    :ok = Events.broadcast_started(user_id, _ticker_id_unknown_yet = nil, request_id)

    with {:ok, user} <- load_user(user_id),
         {:ok, briefing} <- BriefingGenerator.generate(symbol, user, generator_opts) do
      :ok = Events.broadcast_ready(briefing, request_id)
      :ok
    else
      {:error, reason}
      when reason in [:unknown_symbol, :no_trading_profile, :trading_profile_not_loaded] ->
        Logger.warning(
          "BriefingWorker: discarding (#{inspect(reason)}) for symbol=#{symbol} user=#{user_id}"
        )

        :ok = Events.broadcast_failed(user_id, nil, reason, request_id)
        {:discard, reason}

      # LON-174: rate-limited refresh is a discard, not a retry. Oban's
      # default backoff (~15s, 30s, 60s) overlaps the 60s window, so a
      # retry could either fire just-too-soon or just-too-late. User
      # retries by clicking Refresh again; the broadcast tells them.
      {:error, {:rate_limited_refresh, _seconds_remaining} = reason} ->
        Logger.info(
          "BriefingWorker: refresh rate-limited for symbol=#{symbol} user=#{user_id} — #{inspect(reason)}"
        )

        :ok = Events.broadcast_failed(user_id, nil, reason, request_id)
        {:discard, reason}

      {:error, reason} ->
        Logger.warning(
          "BriefingWorker: failed for symbol=#{symbol} user=#{user_id} — #{inspect(reason)}"
        )

        :ok = Events.broadcast_failed(user_id, nil, reason, request_id)
        {:error, reason}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp generate_request_id, do: Ecto.UUID.generate()

  defp load_user(user_id) do
    # `Ash.get/3` by primary key — no dedicated code interface exists
    # for "fetch user by id" yet (read actions on User are all
    # AshAuthentication-specific). If a second consumer appears, add
    # a `get_user_by_id/1` code interface; for one caller this is fine.
    case Ash.get(User, user_id, load: [:trading_profile], authorize?: false) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, :user_not_found}
    end
  end

  # Oban args go through JSON, so keyword opts arrive as a map with
  # string keys. Restore to the keyword shape the Generator expects.
  defp atomize_opts(opts) when is_map(opts) do
    Enum.map(opts, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp atomize_opts(_), do: []

  defp stringify_keys(opts) when is_list(opts) do
    Map.new(opts, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(opts) when is_map(opts), do: opts
end
