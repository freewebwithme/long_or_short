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
end
