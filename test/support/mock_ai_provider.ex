defmodule LongOrShort.AI.MockProvider do
  @moduledoc """
  Mock provider for tests. Stores stubbed responses in process dictionary
  so each test can inject its own behavior without global state.

  ## Usage

      MockProvider.stub(fn _messages, _tools, _opts ->
        {:ok, %{
          tool_calls: [%{name: "save_analysis", input: %{verdict: "GO"}}],
          text: nil,
          usage: %{input_tokens: 100, output_tokens: 50}
        }}
      end)

      LongOrShort.AI.call(messages, tools)
      # => uses the stubbed response

  Records every call for assertion:

      assert MockProvider.calls() |> length() == 1
      assert [{messages, tools, opts}] = MockProvider.calls()
  """
  @behaviour LongOrShort.AI.Provider

  @stub_key {__MODULE__, :stub}
  @calls_key {__MODULE__, :calls}

  @impl LongOrShort.AI.Provider
  def call(messages, tools, opts) do
    record_call(messages, tools, opts)

    case Process.get(@stub_key) do
      nil ->
        {:ok, %{tool_calls: [], text: nil, usage: %{}}}

      fun when is_function(fun, 3) ->
        fun.(messages, tools, opts)
    end
  end

  @doc "Set a stub function for the current process."
  def stub(fun) when is_function(fun, 3) do
    Process.put(@stub_key, fun)
    :ok
  end

  @doc "Return the list of calls made via this provider in the current process, oldest first."
  def calls do
    @calls_key
    |> Process.get([])
    |> Enum.reverse()
  end

  @doc "Reset stub and call history. Useful in test setup."
  def reset do
    Process.delete(@stub_key)
    Process.delete(@calls_key)
    :ok
  end

  defp record_call(messages, tools, opts) do
    existing = Process.get(@calls_key, [])
    Process.put(@calls_key, [{messages, tools, opts} | existing])
  end
end
