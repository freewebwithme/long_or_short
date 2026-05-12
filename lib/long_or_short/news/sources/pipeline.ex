defmodule LongOrShort.News.Sources.Pipeline do
  @moduledoc """
  Stateless helper for the polling lifecycle of `News.Source` feeders.

  Each feeder owns its own GenServer (`use GenServer`, named, with its
  own polling state). The two functions in this module — `init/2` and
  `run_poll/2` — are intended to be called from the feeder's
  `init/1` and `handle_info(:poll, state)` callbacks respectively, so
  the feeder's GenServer body stays at ~6 lines of boilerplate.

  ## State shape

  Pipeline owns one reserved keys in the GenServer state:

    * `:retry_count` — non-negative integer, advanced on `fetch_news`
      errors and reset on success. Drives `Source.Backoff`.

  Feeders are free to add any other keys they need (cursors, counters,
  HTTP client refs, etc.) — `init/2` accepts an `:state` opt that
  becomes the initial map, and `run_poll/2` only touches its own keys.

  ## Polling flow on success

      fetch_news(state)
        → for each raw_item:
            parse_response(raw_item)
              → for each attrs map:
                  Dedup.check_and_mark(source, external_id, symbol)
                    → if first time:
                        News.ingest_article(attrs - :raw_payload, ...)
                          → on success:
                              News.create_article_raw(...) fail-soft (LON-32)
                              broadcast {:new_article, article}
        → reset retry_count, schedule next poll at base interval

  ## Raw payload preservation (LON-32)

  Each `parse_response/1` carries a `:raw_payload` key alongside the
  normalized article attrs. Pipeline strips it before calling
  `News.ingest_article/2` (Article schema rejects unknown keys) and,
  on successful article ingest, upserts a sibling `ArticleRaw` row.

  Raw persistence is **fail-soft** — a failure here logs a warning but
  the article ingest still counts as success. Raw is debugging data,
  not on the critical path.

  ## Polling flow on error

      fetch_news(state) returns {:error, reason, new_state}
        → bump retry_count
        → next interval = Backoff.next_interval(base, retry_count)
        → schedule next poll, log warning

  ## Per-item resilience

  A bad parse on one raw item, or an ingest failure on one article,
  does **not** abort the batch. Each item is handled independently
  and logged. Only `fetch_news/1` returning `{:error, ...}` triggers
  backoff — that's the signal of a source-wide problem.
  """

  require Logger

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.News
  alias LongOrShort.News.Dedup
  alias LongOrShort.Sources.PipelineHelpers

  @doc """
  Initial state + first poll. Call from the feeder's `init/1`.

  ## Options

    * `:state` — initial custom state map (default: `%{}`). Merged on
      top of Pipeline's reserved keys, but Pipeline's keys win on
      conflict (i.e. `:retry_count` is always 0 at startup).
  """
  @spec init(module(), keyword()) :: {:ok, map()}
  def init(module, opts \\ []) do
    initial_custom = Keyword.get(opts, :state, %{})
    state = Map.merge(initial_custom, %{retry_count: 0})

    PipelineHelpers.schedule_first_poll(module)
    {:ok, state}
  end

  @doc """
  Run a single polling cycle. Call from the feeder's
  `handle_info(:poll, state)`.

  Returns the standard `{:noreply, state}` GenServer reply.
  """
  @spec run_poll(module(), map()) :: {:noreply, map()}
  def run_poll(module, state) do
    case module.fetch_news(state) do
      {:ok, raw_items, new_state} ->
        handle_success(module, raw_items, new_state)

      {:error, reason, new_state} ->
        PipelineHelpers.handle_error(module, reason, new_state)
    end
  end

  defp handle_success(module, raw_items, state) do
    {ingested, deduped, errored} = process_batch(module, raw_items)

    Logger.debug(fn ->
      "Polled #{inspect(module)}: " <>
        "#{ingested} ingested, #{deduped} deduped, #{errored} errored " <>
        "(#{length(raw_items)} raw)"
    end)

    # Persist last_success_at so next restart fetches only new articles
    PipelineHelpers.update_source_state(module, :success)

    next_state = Map.put(state, :retry_count, 0)
    PipelineHelpers.schedule_next(module.poll_interval_ms())
    {:noreply, next_state}
  end

  defp process_batch(module, raw_items) do
    Enum.reduce(raw_items, {0, 0, 0}, fn raw, {ing, dedup, err} ->
      case PipelineHelpers.parse_one(module, raw) do
        {:ok, attrs_list} ->
          Enum.reduce(attrs_list, {ing, dedup, err}, &handle_attrs/2)

        {:error, _reason} ->
          {ing, dedup, err + 1}
      end
    end)
  end

  defp handle_attrs(attrs, {ing, dedup, err}) do
    case attrs do
      %{source: source, external_id: ext_id, symbol: sym} ->
        if Dedup.check_and_mark(source, ext_id, sym) do
          case ingest(attrs) do
            {:ok, _article} -> {ing + 1, dedup, err}
            {:error, _} -> {ing, dedup, err + 1}
          end
        else
          {ing, dedup + 1, err}
        end

      _malformed ->
        Logger.warning(
          "Malformed attrs from parse_response (missing source/external_id/symbol): " <>
            inspect(attrs)
        )

        {ing, dedup, err + 1}
    end
  end

  defp ingest(attrs) do
    {raw_payload, ingest_attrs} = Map.pop(attrs, :raw_payload)
    existing_hash = fetch_existing_hash(ingest_attrs)

    case News.ingest_article(ingest_attrs, actor: SystemActor.new()) do
      {:ok, article} ->
        persist_raw(article, raw_payload)

        if existing_hash != article.content_hash do
          broadcast_new_article(article)
        end

        {:ok, article}

      {:error, reason} = err ->
        Logger.warning(
          "ingest_article failed for " <>
            "(#{attrs[:source]}, #{attrs[:external_id]}, #{attrs[:symbol]}): " <>
            "#{inspect(reason)}"
        )

        err
    end
  end

  # Fail-soft raw payload persistence (LON-32). A failure here never
  # affects the article ingest result — raw is debugging data and the
  # critical path is the normalized Article row.
  defp persist_raw(_article, nil), do: :ok

  defp persist_raw(article, raw_payload) do
    case News.create_article_raw(
           %{article_id: article.id, raw_payload: raw_payload},
           actor: SystemActor.new()
         ) do
      {:ok, _article_raw} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "create_article_raw failed for article #{article.id}: " <>
            "#{inspect(reason)} (article ingest succeeded, raw lost)"
        )

        :ok
    end
  end

  defp fetch_existing_hash(%{source: source, external_id: external_id, symbol: symbol}) do
    case News.get_article_content_hash(source, external_id, symbol, actor: SystemActor.new()) do
      {:ok, [%{content_hash: hash} | _]} -> hash
      {:ok, []} -> nil
      {:error, _} -> nil
    end
  end

  defp broadcast_new_article(article) do
    LongOrShort.News.Events.broadcast_new_article(article)
  end
end
