defmodule LongOrShort.Research.Workers.BriefingWorkerTest do
  @moduledoc """
  Tests for the async BriefingWorker (LON-172, PT-1).

  Same `TestProvider` swap pattern as the Generator tests — async:
  false because we mutate the global `:research_briefing_provider`
  config.

  Covers the worker's three PubSub broadcasts (:briefing_started /
  :briefing_ready / :briefing_failed), the `:discard` short-circuit
  for permanent failures, and that `perform/1` exits cleanly under
  Oban.Testing.
  """

  use LongOrShort.DataCase, async: false
  use Oban.Testing, repo: LongOrShort.Repo

  import LongOrShort.AccountsFixtures
  import LongOrShort.TickersFixtures

  alias LongOrShort.Research.Events
  alias LongOrShort.Research.Workers.BriefingWorker

  defmodule TestProvider do
    def call_with_search(_messages, _opts) do
      {:ok,
       %{
         text: "## TL;DR\n\nWorker stub response.",
         citations: [],
         usage: %{input_tokens: 100, output_tokens: 40},
         search_calls: 0
       }}
    end
  end

  defmodule FailingProvider do
    def call_with_search(_messages, _opts), do: {:error, :provider_unavailable}
  end

  setup do
    prior = Application.get_env(:long_or_short, :research_briefing_provider)
    Application.put_env(:long_or_short, :research_briefing_provider, TestProvider)

    on_exit(fn ->
      Application.put_env(:long_or_short, :research_briefing_provider, prior)
    end)

    user = build_trader_user()
    _profile = build_trading_profile(%{user_id: user.id})

    :ok = Events.subscribe_for_user(user.id)

    {:ok, user: user}
  end

  describe "perform/1 — happy path" do
    test "broadcasts :briefing_started then :briefing_ready", %{user: user} do
      ticker = build_ticker(%{symbol: "HAPPY"})
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               perform_job(BriefingWorker, %{
                 "symbol" => "HAPPY",
                 "user_id" => user.id,
                 "request_id" => request_id,
                 "opts" => %{}
               })

      assert_receive {:briefing_started, _ticker_id, ^request_id}
      assert_receive {:briefing_ready, ticker_id, briefing_id, ^request_id}

      assert ticker_id == ticker.id
      assert is_binary(briefing_id)
    end
  end

  describe "perform/1 — permanent failure short-circuit" do
    test "unknown symbol → :discard + :briefing_failed broadcast", %{user: user} do
      request_id = "req-discard-#{System.unique_integer([:positive])}"

      assert {:discard, :unknown_symbol} =
               perform_job(BriefingWorker, %{
                 "symbol" => "NOTREAL",
                 "user_id" => user.id,
                 "request_id" => request_id,
                 "opts" => %{}
               })

      assert_receive {:briefing_started, _, ^request_id}
      assert_receive {:briefing_failed, _ticker_id, :unknown_symbol, ^request_id}
    end
  end

  describe "perform/1 — transient failure" do
    test "provider error → {:error, _} + :briefing_failed broadcast", %{user: user} do
      Application.put_env(:long_or_short, :research_briefing_provider, FailingProvider)
      _ticker = build_ticker(%{symbol: "FAIL"})
      request_id = "req-fail-#{System.unique_integer([:positive])}"

      assert {:error, :provider_unavailable} =
               perform_job(BriefingWorker, %{
                 "symbol" => "FAIL",
                 "user_id" => user.id,
                 "request_id" => request_id,
                 "opts" => %{}
               })

      assert_receive {:briefing_failed, _ticker_id, :provider_unavailable, ^request_id}
    end
  end

  describe "enqueue/3" do
    test "returns {request_id, {:ok, job}} and the job is queued", %{user: user} do
      _ticker = build_ticker(%{symbol: "ENQ"})

      {request_id, {:ok, job}} = BriefingWorker.enqueue("ENQ", user.id)

      assert is_binary(request_id)
      assert %Oban.Job{worker: "LongOrShort.Research.Workers.BriefingWorker"} = job
      assert job.args["symbol"] == "ENQ"
      assert job.args["user_id"] == user.id
      assert job.args["request_id"] == request_id
    end
  end
end
