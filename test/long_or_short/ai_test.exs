defmodule LongOrShort.AITest do
  use ExUnit.Case, async: true

  alias LongOrShort.AI
  alias LongOrShort.AI.MockProvider

  setup do
    MockProvider.reset()
    :ok
  end

  describe "call/3" do
    test "routes to the configured provider by default" do
      MockProvider.stub(fn _msg, _tools, _opts ->
        {:ok, %{tool_calls: [%{name: "test", input: %{}}], text: nil, usage: %{}}}
      end)

      assert {:ok, response} = AI.call([%{role: "user", content: "hi"}], [])
      assert response.tool_calls == [%{name: "test", input: %{}}]
    end

    test "records the call on MockProvider" do
      messages = [%{role: "user", content: "hi"}]
      tools = [%{name: "t", description: "", input_schema: %{}}]

      AI.call(messages, tools, model: "fake-model")

      assert [{recorded_messages, recorded_tools, recorded_opts}] = MockProvider.calls()
      assert recorded_messages == messages
      assert recorded_tools == tools
      assert recorded_opts == [model: "fake-model"]
    end

    test "explicit :provider opt overrides the configured default" do
      defmodule OneOffProvider do
        @behaviour LongOrShort.AI.Provider
        @impl true
        def call(_msgs, _tools, _opts),
          do: {:ok, %{tool_calls: [], text: "from-one-off", usage: %{}}}
      end

      assert {:ok, %{text: "from-one-off"}} =
               AI.call([], [], provider: OneOffProvider)

      # MockProvider should not have been called
      assert MockProvider.calls() == []
    end

    test ":provider opt is not leaked to the provider" do
      MockProvider.stub(fn _msgs, _tools, opts ->
        refute Keyword.has_key?(opts, :provider)
        {:ok, %{tool_calls: [], text: nil, usage: %{}}}
      end)

      AI.call([], [], provider: MockProvider, model: "foo")
    end

    test "returns provider error as-is" do
      MockProvider.stub(fn _, _, _ -> {:error, :boom} end)

      assert {:error, :boom} = AI.call([], [])
    end
  end

  describe "call/3 — rate-limit retry" do
    # MockProvider records calls via an ETS `:bag` table which dedupes
    # identical tuples. Since retries replay the SAME args, `calls()`
    # collapses to 1 entry regardless of how many physical attempts
    # ran. So we count via an `:atomics` counter inside the stub
    # itself.
    setup do
      counter = :counters.new(1, [:atomics])
      {:ok, counter: counter}
    end

    defp count_attempts(counter), do: :counters.get(counter, 1)
    defp record_attempt(counter), do: :counters.add(counter, 1, 1)

    test "retries on {:rate_limited, _} until success", %{counter: counter} do
      MockProvider.stub(fn _, _, _ ->
        record_attempt(counter)

        case count_attempts(counter) do
          1 -> {:error, {:rate_limited, "1"}}
          _ -> {:ok, %{tool_calls: [], text: "ok-after-retry", usage: %{}}}
        end
      end)

      assert {:ok, %{text: "ok-after-retry"}} =
               AI.call([%{role: "user", content: "hi"}], [])

      # 1 rate-limited + 1 success = 2 attempts
      assert count_attempts(counter) == 2
    end

    test "gives up after @max_retries and returns the last rate-limit error",
         %{counter: counter} do
      MockProvider.stub(fn _, _, _ ->
        record_attempt(counter)
        {:error, {:rate_limited, "1"}}
      end)

      assert {:error, {:rate_limited, "1"}} = AI.call([], [])

      # initial + 2 retries = 3 total attempts
      assert count_attempts(counter) == 3
    end

    test "retry: false opts out of retry, surfaces rate_limited error",
         %{counter: counter} do
      MockProvider.stub(fn _, _, _ ->
        record_attempt(counter)
        {:error, {:rate_limited, "1"}}
      end)

      assert {:error, {:rate_limited, "1"}} = AI.call([], [], retry: false)
      assert count_attempts(counter) == 1
    end

    test "non-rate-limit errors are not retried", %{counter: counter} do
      MockProvider.stub(fn _, _, _ ->
        record_attempt(counter)
        {:error, :network_error}
      end)

      assert {:error, :network_error} = AI.call([], [])
      assert count_attempts(counter) == 1
    end
  end
end
