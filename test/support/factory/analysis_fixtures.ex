defmodule LongOrShort.AnalysisFixtures do
  @moduledoc """
  Test fixtures for the Analysis domain.
  """

  alias LongOrShort.NewsFixtures

  @doc """
  Default attributes for a complete NewsAnalysis. Caller supplies
  `:article_id` separately via overrides.
  """
  def valid_news_analysis_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        verdict: :trade,
        headline_takeaway: "Catalyst-driven move with clear continuation setup.",
        catalyst_strength: :strong,
        catalyst_type: :partnership,
        sentiment: :positive,
        llm_provider: :claude,
        llm_model: "claude-opus-4-7"
      },
      overrides
    )
  end

  @doc """
  Builds a NewsAnalysis via the `:create` action. Lazily creates an
  Article fixture if `:article_id` is not supplied, and a trader user
  if `:user_id` is not supplied (LON-109 — every analysis is now
  attributed to a user).

  When the test mounts a LiveView as a specific user and expects to
  see this analysis through `Article.news_analysis` (actor-filtered
  has_one) or any read action (own-row policy), pass `:user_id` to
  align — otherwise the lazy-built trader will not match the actor
  and the relationship/read returns nil.
  """
  def build_news_analysis(overrides \\ %{}) do
    import LongOrShort.AccountsFixtures, only: [build_trader_user: 0]

    article_id =
      Map.get_lazy(overrides, :article_id, fn ->
        NewsFixtures.build_article().id
      end)

    user_id =
      Map.get_lazy(overrides, :user_id, fn ->
        build_trader_user().id
      end)

    attrs =
      overrides
      |> Map.drop([:article_id, :user_id])
      |> valid_news_analysis_attrs()
      |> Map.put(:article_id, article_id)
      |> Map.put(:user_id, user_id)

    case LongOrShort.Analysis.create_news_analysis(attrs, authorize?: false) do
      {:ok, analysis} ->
        analysis

      {:error, error} ->
        raise """
        Failed to create news_analysis fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end
end
