# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     LongOrShort.Repo.insert!(%LongOrShort.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.
require Ash.Query

# ── Admin bootstrap (LON-127) ──────────────────────────────────────
#
# First-deploy idempotent seed: if ADMIN_EMAIL + ADMIN_PASSWORD env
# vars are both set AND no user exists for that email yet, create
# one with role :admin and confirmed_at populated.
#
# We bypass parts of the normal `register_with_password` flow:
#   1. The User resource has `confirm_on_create? true` +
#      `require_interaction? true`, but prod mailer is still
#      Swoosh.Adapters.Local (LON-127 risks). Setting
#      `confirmed_at` directly lets the admin sign in without a
#      live mailer wired up.
#   2. `register_with_password` always sets role :trader; the
#      catch-all `:update` action accepts no attributes by design.
#      Promotion uses `force_change_attribute` inside an
#      `authorize?: false` context.
#
# Re-running the seed is safe — the email lookup short-circuits
# before any side effects fire.
admin_email = System.get_env("ADMIN_EMAIL")
admin_password = System.get_env("ADMIN_PASSWORD")

cond do
  is_nil(admin_email) or admin_email == "" ->
    IO.puts("[seeds] ADMIN_EMAIL unset — skipping admin bootstrap.")

  is_nil(admin_password) or admin_password == "" ->
    IO.puts("[seeds] ADMIN_PASSWORD unset — skipping admin bootstrap.")

  true ->
    existing =
      LongOrShort.Accounts.User
      |> Ash.Query.filter(email == ^admin_email)
      |> Ash.read_one!(authorize?: false)

    case existing do
      nil ->
        register_result =
          LongOrShort.Accounts.User
          |> Ash.Changeset.for_create(:register_with_password, %{
            email: admin_email,
            password: admin_password,
            password_confirmation: admin_password
          })
          |> Ash.create(authorize?: false)

        case register_result do
          {:ok, user} ->
            {:ok, _promoted} =
              user
              |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
              |> Ash.Changeset.force_change_attribute(:role, :admin)
              |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
              |> Ash.update(authorize?: false)

            IO.puts("[seeds] Admin user bootstrapped: #{admin_email}")

          {:error, error} ->
            IO.puts(
              "[seeds] Admin bootstrap failed on field(s): " <>
                LongOrShort.Seeds.invalid_fields(error) <>
                ". Check ADMIN_EMAIL/ADMIN_PASSWORD (password must be >= 8 chars). Skipping."
            )
        end

      _user ->
        IO.puts("[seeds] Admin user already exists: #{admin_email} — skipping.")
    end
end

# ── Trader bootstrap (LON-127) ─────────────────────────────────────
#
# Solo-use convenience: same login (password) as admin, but a
# distinct :trader account so the trading workflow runs through the
# normal non-admin path (policies, /watchlist, /analyze, etc.).
#
# Same-email isn't possible — User has `identity :unique_email`.
# We derive the trader email via plus-addressing
# (`local+trader@domain`) from `ADMIN_EMAIL`. Most ESPs (Gmail,
# Protonmail, Fastmail, ...) route plus-addressed mail to the same
# inbox, so practical UX is "one mailbox, one password, two
# accounts". Override with `TRADER_EMAIL` for non-plus-friendly
# providers.
#
# Confirmation handling is identical to the admin block.
trader_email =
  System.get_env("TRADER_EMAIL") ||
    case admin_email && String.split(admin_email, "@", parts: 2) do
      [local, domain] -> "#{local}+trader@#{domain}"
      _ -> nil
    end

trader_password = System.get_env("TRADER_PASSWORD") || admin_password

cond do
  is_nil(trader_email) or trader_email == "" ->
    IO.puts("[seeds] No trader email derivable — skipping trader bootstrap.")

  is_nil(trader_password) or trader_password == "" ->
    IO.puts("[seeds] No trader password available — skipping trader bootstrap.")

  true ->
    existing_trader =
      LongOrShort.Accounts.User
      |> Ash.Query.filter(email == ^trader_email)
      |> Ash.read_one!(authorize?: false)

    case existing_trader do
      nil ->
        register_result =
          LongOrShort.Accounts.User
          |> Ash.Changeset.for_create(:register_with_password, %{
            email: trader_email,
            password: trader_password,
            password_confirmation: trader_password
          })
          |> Ash.create(authorize?: false)

        case register_result do
          {:ok, user} ->
            # Role defaults to :trader from the resource — we only need
            # to flip confirmed_at to bypass the Local-adapter mailer
            # gap.
            {:ok, _confirmed} =
              user
              |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
              |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
              |> Ash.update(authorize?: false)

            IO.puts("[seeds] Trader user bootstrapped: #{trader_email}")

          {:error, error} ->
            IO.puts(
              "[seeds] Trader bootstrap failed on field(s): " <>
                LongOrShort.Seeds.invalid_fields(error) <>
                ". Check TRADER_PASSWORD (or ADMIN_PASSWORD fallback — must be >= 8 chars). Skipping."
            )
        end

      _user ->
        IO.puts("[seeds] Trader user already exists: #{trader_email} — skipping.")
    end
end

# ── TradingProfile seed (pre-existing) ─────────────────────────────
# Seeds a default TradingProfile for the first :trader user if one
# exists. On a brand-new deploy this is a no-op until somebody
# registers as a trader (the admin user above is excluded).
trader =
  LongOrShort.Accounts.User
  |> Ash.Query.filter(role == :trader)
  |> Ash.Query.limit(1)
  |> Ash.read!(authorize?: false)
  |> List.first()

case trader do
  nil ->
    IO.puts("[seeds] No trader user found — skipping TradingProfile seed.")

  user ->
    {:ok, _profile} =
      LongOrShort.Accounts.upsert_trading_profile(
        %{
          user_id: user.id,
          trading_style: :momentum_day,
          time_horizon: :intraday,
          market_cap_focuses: [:micro, :small],
          catalyst_preferences: [
            :partnership,
            :fda,
            :ma,
            :contract_win,
            :clinical,
            :regulatory
          ],
          price_min: Decimal.new("2.0"),
          price_max: Decimal.new("10.0"),
          float_max: 50_000_000
        },
        authorize?: false
      )

    IO.puts("[seeds] TradingProfile seeded for #{user.email}")
end
