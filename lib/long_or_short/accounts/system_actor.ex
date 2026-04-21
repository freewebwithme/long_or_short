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

      * no external API exposure
      * no user-controlled data path reaches actor construction
      * single-developer codebase

    **Before any of those change, migrate to the `public? false` +
    `private_action?()` bypass pattern.** See TICKET-### for details.

    See LON-15 ticket

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
