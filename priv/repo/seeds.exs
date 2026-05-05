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
