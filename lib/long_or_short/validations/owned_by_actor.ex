defmodule LongOrShort.Validations.OwnedByActor do
  @moduledoc """
  Enforces per-user ownership on create / upsert actions by requiring
  the changeset's `:user_id` attribute to equal the authenticated
  actor's id.

  Use this on create and upsert actions where Ash policy expressions
  cannot reference changeset attributes (the row doesn't exist yet, so
  `authorize_if expr(user_id == ^actor(:id))` is rejected). For update
  and read actions, prefer the policy `expr/1` form — this module is
  only for the create-time gap.

  ## Bypasses

    * **Nil actor** — deferred to the caller (typically the policy layer
      rejects anonymous calls; tests using `authorize?: false` and no
      actor pass through unchallenged).
    * **System actor** (`%{system?: true}`) — background feeders.
    * **Admin actor** (`%{role: :admin}`) — admins manage any user's row.

  ## Usage

      create :upsert do
        accept [:user_id, ...]
        upsert? true
        upsert_identity :unique_user

        validate LongOrShort.Validations.OwnedByActor
      end

  ## History

  Extracted in LON-139 after the same inline pattern appeared in three
  resources (LongOrShort.Tickers.WatchlistItem,
  LongOrShort.Accounts.TradingProfile, LongOrShort.Accounts.UserProfile).
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    case Map.get(context, :actor) do
      nil ->
        :ok

      %{system?: true} ->
        :ok

      %{role: :admin} ->
        :ok

      actor ->
        if Ash.Changeset.get_attribute(changeset, :user_id) == actor.id do
          :ok
        else
          {:error, field: :user_id, message: "must match the authenticated user"}
        end
    end
  end
end
