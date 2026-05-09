defmodule LongOrShort.Filings.Extractor.Router do
  @moduledoc """
  Selects which AI model handles each SEC filing type.

  > **Naming note**: this is an AI-model dispatch helper for
  > `LongOrShort.Filings.Extractor` — it is **not** related to
  > `Phoenix.Router` or any HTTP routing concept.

  ## Two-step routing

    1. `tier_for/2` — provider-agnostic semantic tier
       (`:cheap | :complex`) per filing type. Expresses intent
       ("how strong does this call need to be?") without naming any
       provider model.
    2. `model_for_tier/2` — looks up the concrete model ID for the
       given tier and provider via the `:filing_extraction_models`
       config map.

  Splitting the two keeps this module free of provider-specific
  model strings. Adding a new provider (e.g. Qwen via LON-104) is
  just one extra entry in `config/config.exs` — no code change here.

  ## Tier policy (LON-113)

  `:cheap` (Haiku-tier on Claude, or equivalent on other providers) —
  short, formulaic, low quality risk:

    * `:_8k` (default, including `Item 3.02` PIPE deals)
    * `:def14a` (proxy statements)
    * `:_13d`, `:_13g` (beneficial ownership reports)

  `:complex` (Sonnet-tier on Claude, or equivalent) — long, varied
  prose, higher quality risk:

    * `:s1`, `:s1a` (initial registration statements)
    * `:s3`, `:s3a` (shelf registrations)
    * `:_424b1`..`:_424b5` (final prospectuses)
    * `:_8k` with `Item 1.01` (material definitive agreements —
      terms vary widely from short underwriting agreements to
      multi-page complex deals)

  See `LongOrShort.Filings.SectionFilter`'s glossary for what each
  filing type discloses.

  ## Cascade interaction (LON-41)

  Static per-filing-type tiering is the Phase 1 design.
  LON-41's confidence-based Haiku→Sonnet escalation will sit on top
  later — `tier_for/2`'s output becomes the *initial* tier rather
  than the final one.
  """

  # Filing types that always go through the cheap tier regardless of subtype.
  @cheap_filing_types ~w(def14a _13d _13g)a

  # Prospectus and final-prospectus types that always go through the complex tier.
  @complex_prospectus_types ~w(s1 s1a s3 s3a _424b1 _424b2 _424b3 _424b4 _424b5)a

  @typedoc "Provider-agnostic capability tier."
  @type tier :: :cheap | :complex

  @doc """
  Returns the semantic tier for the given filing type and (optional)
  subtype. Provider-agnostic.

  ## Examples

      iex> alias LongOrShort.Filings.Extractor.Router
      iex> Router.tier_for(:s1)
      :complex

      iex> alias LongOrShort.Filings.Extractor.Router
      iex> Router.tier_for(:def14a)
      :cheap

      iex> alias LongOrShort.Filings.Extractor.Router
      iex> Router.tier_for(:_8k, "8-K Item 1.01")
      :complex

      iex> alias LongOrShort.Filings.Extractor.Router
      iex> Router.tier_for(:_8k, "8-K Item 3.02")
      :cheap
  """
  @spec tier_for(atom(), String.t() | nil) :: tier()
  def tier_for(filing_type, filing_subtype \\ nil)

  def tier_for(:_8k, subtype) when is_binary(subtype) do
    if material_agreement?(subtype), do: :complex, else: :cheap
  end

  def tier_for(:_8k, _no_subtype), do: :cheap

  def tier_for(filing_type, _) when filing_type in @cheap_filing_types,
    do: :cheap

  def tier_for(filing_type, _) when filing_type in @complex_prospectus_types,
    do: :complex

  @doc """
  Resolves a tier into a concrete model ID for the given AI provider.

  When `provider` is `nil` (the default), uses the provider currently
  configured under `:ai_provider`. Tests that need a fixed provider
  regardless of global config can pass it explicitly.

  Raises if `:filing_extraction_models` has no entry for the resolved
  provider — that's a config bug worth surfacing loudly rather than
  silently falling back.

  ## Examples

      iex> alias LongOrShort.Filings.Extractor.Router
      iex> Router.model_for_tier(:complex, LongOrShort.AI.Providers.Claude)
      "claude-sonnet-4-6"

      iex> alias LongOrShort.Filings.Extractor.Router
      iex> Router.model_for_tier(:cheap, LongOrShort.AI.Providers.Claude)
      "claude-haiku-4-5-20251001"
  """
  @spec model_for_tier(tier(), module() | nil) :: String.t()
  def model_for_tier(tier, provider \\ nil) do
    provider = provider || Application.fetch_env!(:long_or_short, :ai_provider)

    :long_or_short
    |> Application.fetch_env!(:filing_extraction_models)
    |> Map.fetch!(provider)
    |> Map.fetch!(tier)
  end

  # 8-K Item 1.01 = "Entry into a Material Definitive Agreement". These
  # range from boilerplate underwriting agreements to multi-page complex
  # deal terms — the complex tier earns its keep here.
  defp material_agreement?(subtype), do: String.contains?(subtype, "1.01")
end
