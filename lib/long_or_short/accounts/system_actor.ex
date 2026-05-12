defmodule LongOrShort.Accounts.SystemActor do
  @moduledoc """
  Actor struct used by background jobs and data feeders.

  Represents non-human trusted callers (GenServer pollers, seed scripts,
  scheduled jobs). Bypasses all resource policies — use only from code
  paths that do not originate from end-user input.

  ## ⚠️ Security note — planned replacement

  This struct is trivially constructable from anywhere in the codebase,
  which means any accidental `actor: SystemActor.new()` grants full
  bypass. For MVP this is acceptable because:

    * no external API exposure (no AshJsonApi, no AshGraphql)
    * no user-controlled data path reaches actor construction
    * single-developer codebase
    * web layer audit (`rg SystemActor lib/long_or_short_web/`) returns 0

  As of 2026-05-12, **13 resources** rely on this bypass pattern via
  `bypass actor_attribute_equals(:system?, true)`:

    * Tickers — `Ticker`, `WatchlistItem`
    * News — `Article`, `ArticleRaw`
    * Filings — `Filing`, `FilingRaw`, `FilingAnalysis`, `InsiderTransaction`
    * Analysis — `NewsAnalysis`
    * Accounts — `UserProfile`, `TradingProfile`
    * Settings — `Setting`
    * Sources — `SourceState`

  Web-layer leakage is structurally prevented by the test in
  `test/long_or_short/accounts/system_actor_boundary_test.exs`. Do not
  introduce `SystemActor` references inside `lib/long_or_short_web/` —
  that test will fail CI.

  **Migrate to `public? false` + `private_action?()` bypass pattern
  before any of these happen:** AshJsonApi/AshGraphql exposure, a second
  developer joining, public launch, or any code path that lets
  user-submitted Elixir terms reach actor construction. See LON-15.

  ## Example

      iex> actor = LongOrShort.Accounts.SystemActor.new()
      iex> LongOrShort.Tickers.upsert_ticker_by_symbol(
      ...>   %{symbol: "BTBD", company_name: "Bit Digital"},
      ...>   actor: actor
      ...> )
  """

  @enforce_keys [:system?]
  defstruct system?: true, name: "system"

  @type t :: %__MODULE__{system?: true, name: String.t()}

  @spec new(String.t()) :: t()
  def new(name \\ "system") do
    %__MODULE__{system?: true, name: name}
  end
end
