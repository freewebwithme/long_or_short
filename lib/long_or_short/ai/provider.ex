defmodule LongOrShort.AI.Provider do
  @moduledoc """
  Behaviour for LLM providers (Claude, Qwen, etc.).

  All providers normalize their responses to the same shape so callers
  (e.g. `LongOrShort.Analysis.NewsAnalyzer`) don't need to know
  which provider is being used.

  ## Adding a new provider

  Implement this behaviour with a single `call/3` callback that:

  1. Accepts a list of messages and a list of tool specs
  2. Calls the provider's API
  3. Normalizes the response into `t:response/0`
  """

  @typedoc "A single chat message in OpenAI/Anthropic format."
  @type message :: %{role: String.t(), content: String.t()}

  @typedoc """
  A tool the model can choose to call.

  `input_schema` is a JSON schema describing the tool's parameters.
  """
  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @typedoc "Provider-specific options (model name, max_tokens, etc.)."
  @type opts :: keyword()

  @typedoc "A normalized tool call extracted from the model's response."
  @type tool_call :: %{name: String.t(), input: map()}

  @typedoc "Token usage stats returned by the provider."
  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer()
        }

  @typedoc "Normalized provider response."
  @type response ::
          {:ok, %{tool_calls: [tool_call()], text: String.t() | nil, usage: usage()}}
          | {:error, term()}

  @doc """
  Send messages + tools to the LLM and return a normalized response.

  Implementations MUST translate provider-specific response shapes
  into the common `t:response/0` format.
  """
  @callback call([message()], [tool_spec()], opts()) :: response()
end
