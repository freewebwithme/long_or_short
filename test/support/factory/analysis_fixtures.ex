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
  Article fixture if `:article_id` is not supplied.
  """
  def build_news_analysis(overrides \\ %{}) do
    article_id =
      Map.get_lazy(overrides, :article_id, fn ->
        NewsFixtures.build_article().id
      end)

    attrs =
      overrides
      |> Map.delete(:article_id)
      |> valid_news_analysis_attrs()
      |> Map.put(:article_id, article_id)

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
