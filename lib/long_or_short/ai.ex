defmodule LongOrShort.AI do
  @moduledoc """
  Facade for LLM provider calls.

  Callers route every LLM call through `LongOrShort.AI.call/3`, never
  through a specific provider module. This keeps the rest of the
  codebase free of provider-specific knowledge — swapping Claude for
  another model is a config change, not a code change.

  ## Configuration

      config :long_or_short, :ai_provider, LongOrShort.AI.Providers.Claude

  ## Usage

      LongOrShort.AI.call(messages, tools, model: "claude-sonnet-4-20250514")

  Pass `:provider` in opts to override the configured default (useful
  for tests or A/B comparisons):

      LongOrShort.AI.call(messages, tools, provider: MyMockProvider)
  """

  @type messages :: [LongOrShort.AI.Provider.message()]
  @type tools :: [LongOrShort.AI.Provider.tool_spec()]
  @type opts :: keyword()

  @doc """
  Send messages + tools to the configured (or overridden) LLM provider.

  Returns the provider's normalized `t:LongOrShort.AI.Provider.response/0`.
  """
  @spec call(messages(), tools(), opts()) :: LongOrShort.AI.Provider.response()
  def call(messages, tools, opts \\ []) do
    {provider, opts} = Keyword.pop(opts, :provider, default_provider())
    provider.call(messages, tools, opts)
  end

  def default_provider, do: Application.fetch_env!(:long_or_short, :ai_provider)
end
