defmodule LongOrShort.AI.MockProvider do
  @moduledoc """
  In-process mock for `LongOrShort.AI.Provider`. Use it from any test
  that exercises code which eventually calls `LongOrShort.AI.call/3`.

  ## Why this exists

  Production code routes every LLM call through the configured provider
  module. In tests we point `:ai_provider` at this module so we can:

    * inject deterministic responses without hitting the network,
    * assert on exactly what messages/tools/opts were sent,
    * exercise both happy paths and the full error vocabulary
      (`:rate_limited`, `:network_error`, `:http_error`, `:invalid_response`).

  ## Process boundaries

  Tests rarely call `AI.call/3` directly — more often a LiveView spawns
  a `Task.Supervisor` child that calls it. The mock therefore has to
  work across process boundaries:

    * stubs and recorded calls are owned by a *test process*, but
    * the actual `call/3` invocation happens in some descendant
      (a LiveView, a Task, a worker GenServer triggered from one).

  We resolve this by walking the `:"$callers"` chain that Elixir
  populates whenever a process spawns another via `Task`,
  `Task.Supervisor`, or `Phoenix.LiveViewTest`. The first ancestor
  whose process dictionary holds our stub key is treated as the
  "owner" of the call — that's where recordings are stored and where
  the stub is read from.

  ## Storage

    * **Stub function**: stored in the owner's process dictionary under
      `{__MODULE__, :stub}`. Only the owner ever writes here, so no
      synchronization needed.
    * **Recorded calls**: stored in a `:bag` ETS table
      (`#{inspect(__MODULE__)}.Calls`) keyed by owner PID. We can't
      write to another process's dictionary, hence ETS. The table must
      be created once at test-suite start; see
      `LongOrShort.AI.MockProvider.init/0`.

  ## Usage

      MockProvider.init()                      # in test_helper.exs, once
      MockProvider.reset()                     # in test setup

      MockProvider.stub(fn _messages, _tools, _opts ->
        {:ok, %{
          tool_calls: [%{name: "save_analysis", input: %{verdict: "GO"}}],
          text: nil,
          usage: %{input_tokens: 100, output_tokens: 50}
        }}
      end)

      LongOrShort.AI.call(messages, tools)
      # => uses the stubbed response, even if invoked from a Task

      assert [{messages, tools, opts}] = MockProvider.calls()

  ## Concurrency

  Safe for `async: true`: stubs live in per-process dictionaries and
  ETS rows are keyed by owner PID, so parallel tests never see each
  other's data.
  """
  @behaviour LongOrShort.AI.Provider

  @stub_key {__MODULE__, :stub}
  @search_stub_key {__MODULE__, :search_stub}
  @table __MODULE__.Calls

  @doc """
  Create the ETS table used to record calls. Call once from
  `test_helper.exs` before any test runs.

  Idempotent: safe to call multiple times.
  """
  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :bag])
      _ref -> @table
    end

    :ok
  end

  @impl LongOrShort.AI.Provider
  def call(messages, tools, opts) do
    owner = owner_pid(@stub_key)
    # Untagged 3-tuple — legacy contract that tests pattern-match
    # directly as `[{messages, tools, opts}]`. Don't tag this without
    # updating every existing call site.
    :ets.insert(@table, {owner, {messages, tools, opts}})

    case stub_for(owner, @stub_key) do
      nil -> {:ok, %{tool_calls: [], text: nil, usage: %{}}}
      fun when is_function(fun, 3) -> fun.(messages, tools, opts)
    end
  end

  @doc """
  Quacks like `LongOrShort.AI.Providers.Claude.call_with_search/2`.
  Returns `{:ok, %{text, citations, usage, search_calls}}` from the
  stub set via `stub_search/1`, or a benign default if no stub is set.

  Use this when the code under test goes through a `:morning_brief_provider`
  / `:research_briefing_provider` config flip pointed at MockProvider.

  Recordings are stored as 2-tuples `{messages, opts}`, distinguishable
  from `call/3`'s 3-tuples by `tuple_size/1` — see `search_calls/0`.
  """
  def call_with_search(messages, opts) do
    owner = owner_pid(@search_stub_key)
    :ets.insert(@table, {owner, {messages, opts}})

    case stub_for(owner, @search_stub_key) do
      nil ->
        {:ok,
         %{
           text: "",
           citations: [],
           usage: %{input_tokens: 0, output_tokens: 0},
           search_calls: 0
         }}

      fun when is_function(fun, 2) ->
        fun.(messages, opts)
    end
  end

  @doc """
  Set the tool-use `call/3` stub for the current process. Visible to
  descendant processes that propagate `:"$callers"` (Task,
  Task.Supervisor, Phoenix.LiveViewTest, …).
  """
  @spec stub((list(), list(), keyword() -> {:ok, map()} | {:error, term()})) :: :ok
  def stub(fun) when is_function(fun, 3) do
    Process.put(@stub_key, fun)
    :ok
  end

  @doc """
  Set the `call_with_search/2` stub for the current process. Separate
  key from `stub/1` so a single test can pre-set both behaviours
  without one clobbering the other.
  """
  @spec stub_search((list(), keyword() -> {:ok, map()} | {:error, term()})) :: :ok
  def stub_search(fun) when is_function(fun, 2) do
    Process.put(@search_stub_key, fun)
    :ok
  end

  @doc """
  Return all calls made under the current process's ownership, oldest
  first. Each entry is an untagged tuple — `{messages, tools, opts}`
  for `call/3` (3-tuple) or `{messages, opts}` for `call_with_search/2`
  (2-tuple). Distinguish by `tuple_size/1` or use `search_calls/0`
  for the filtered view.
  """
  @spec calls() :: [tuple()]
  def calls do
    @table
    |> :ets.lookup(self())
    |> Enum.map(fn {_owner, call} -> call end)
  end

  @doc """
  Filtered helper: only the `call_with_search/2` invocations, oldest
  first. Each entry is `{messages, opts}`.
  """
  @spec search_calls() :: [{list(), keyword()}]
  def search_calls do
    Enum.filter(calls(), fn t -> tuple_size(t) == 2 end)
  end

  @doc """
  Clear both stubs and call history for the current process. Call
  from test setup so each test starts clean.
  """
  @spec reset() :: :ok
  def reset do
    Process.delete(@stub_key)
    Process.delete(@search_stub_key)
    :ets.delete(@table, self())
    :ok
  end

  # ── internals ──────────────────────────────────────────────────────

  # Walk [self() | $callers], return the first PID whose dictionary
  # holds the requested stub key. Falls back to self() if nothing is
  # found — that's the right behaviour when AI.call/3 is invoked
  # directly from the test process without a stub set.
  defp owner_pid(key) do
    Enum.find(caller_chain(), self(), &has_stub?(&1, key))
  end

  defp stub_for(pid, key) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case List.keyfind(dict, key, 0) do
          {_key, value} -> value
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp has_stub?(pid, key), do: stub_for(pid, key) != nil

  defp caller_chain do
    [self() | Process.get(:"$callers", [])]
  end
end
