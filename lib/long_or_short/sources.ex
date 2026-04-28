defmodule LongOrShort.Sources do
  @moduledoc """
  Sources domain — persistent polling metadata for each news source.

  Tracks per-source state across server restarts so feeders can avoid
  redundant API calls and duplicate broadcasts.
  """

  use Ash.Domain, otp_app: :long_or_short

  resources do
    resource LongOrShort.Sources.SourceState do
      define :get_source_state, action: :read, get_by: [:source]
      define :upsert_source_state, action: :upsert
    end
  end
end
