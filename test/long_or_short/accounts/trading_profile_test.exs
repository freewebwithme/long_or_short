defmodule LongOrShort.Accounts.TradingProfileTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.AccountsFixtures

  alias LongOrShort.Accounts

  describe "create_trading_profile/2" do
    test "creates a profile with valid attrs" do
      user = build_trader_user()
      attrs = valid_trading_profile_attrs(%{user_id: user.id})

      {:ok, profile} = Accounts.create_trading_profile(attrs, authorize?: false)

      assert profile.user_id == user.id
      assert profile.trading_style == :momentum_day
      assert profile.market_cap_focuses == [:micro, :small]
      assert Decimal.equal?(profile.price_min, Decimal.new("2.0"))
      assert profile.float_max == 50_000_000
    end

    test "applies defaults for catalyst_preferences and market_cap_focuses" do
      user = build_trader_user()

      attrs =
        valid_trading_profile_attrs(%{user_id: user.id})
        |> Map.drop([:catalyst_preferences, :market_cap_focuses])

      {:ok, profile} = Accounts.create_trading_profile(attrs, authorize?: false)

      assert profile.catalyst_preferences == []
      assert profile.market_cap_focuses == []
    end

    test "rejects invalid :trading_style" do
      user = build_trader_user()
      attrs = valid_trading_profile_attrs(%{user_id: user.id, trading_style: :bogus})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.create_trading_profile(attrs, authorize?: false)

      assert error_on_field?(error, :trading_style)
    end

    test "rejects invalid :time_horizon" do
      user = build_trader_user()
      attrs = valid_trading_profile_attrs(%{user_id: user.id, time_horizon: :forever})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.create_trading_profile(attrs, authorize?: false)

      assert error_on_field?(error, :time_horizon)
    end

    test "rejects invalid item in :market_cap_focuses" do
      user = build_trader_user()

      attrs =
        valid_trading_profile_attrs(%{
          user_id: user.id,
          market_cap_focuses: [:micro, :bogus]
        })

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.create_trading_profile(attrs, authorize?: false)

      assert error_on_field?(error, :market_cap_focuses)
    end

    test "rejects invalid item in :catalyst_preferences" do
      user = build_trader_user()

      attrs =
        valid_trading_profile_attrs(%{
          user_id: user.id,
          catalyst_preferences: [:partnership, :nope]
        })

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.create_trading_profile(attrs, authorize?: false)

      assert error_on_field?(error, :catalyst_preferences)
    end

    test "accepts an empty :catalyst_preferences array" do
      user = build_trader_user()
      attrs = valid_trading_profile_attrs(%{user_id: user.id, catalyst_preferences: []})

      assert {:ok, profile} = Accounts.create_trading_profile(attrs, authorize?: false)
      assert profile.catalyst_preferences == []
    end
  end

  describe "unique_user identity" do
    test "second :create with same user_id is rejected" do
      user = build_trader_user()
      _first = build_trading_profile(%{user_id: user.id})

      attrs = valid_trading_profile_attrs(%{user_id: user.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.create_trading_profile(attrs, authorize?: false)
    end
  end

  describe "upsert_trading_profile/2" do
    test "first call inserts, second call with same user_id updates the same row" do
      user = build_trader_user()

      {:ok, first} =
        Accounts.upsert_trading_profile(
          valid_trading_profile_attrs(%{user_id: user.id, trading_style: :swing}),
          authorize?: false
        )

      {:ok, second} =
        Accounts.upsert_trading_profile(
          valid_trading_profile_attrs(%{
            user_id: user.id,
            trading_style: :momentum_day,
            notes: "switched back"
          }),
          authorize?: false
        )

      assert second.id == first.id
      assert second.trading_style == :momentum_day
      assert second.notes == "switched back"
    end
  end

  describe "update_trading_profile/3" do
    test "updates editable fields" do
      user = build_trader_user()
      profile = build_trading_profile(%{user_id: user.id, trading_style: :momentum_day})

      {:ok, updated} =
        Accounts.update_trading_profile(
          profile,
          %{trading_style: :swing, notes: "shifted to swing"},
          authorize?: false
        )

      assert updated.id == profile.id
      assert updated.trading_style == :swing
      assert updated.notes == "shifted to swing"
    end

    test "rejects attrs outside the accept list (e.g. user_id)" do
      user_a = build_trader_user()
      user_b = build_trader_user()
      profile = build_trading_profile(%{user_id: user_a.id})

      # user_id is not in the :update accept list — Ash raises NoSuchInput
      # which is the right protection against ownership tampering.
      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.update_trading_profile(
                 profile,
                 %{notes: "tweaked", user_id: user_b.id},
                 authorize?: false
               )
    end

    test "rejects invalid trading_style" do
      user = build_trader_user()
      profile = build_trading_profile(%{user_id: user.id})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.update_trading_profile(
                 profile,
                 %{trading_style: :bogus},
                 authorize?: false
               )

      assert error_on_field?(error, :trading_style)
    end
  end

  describe "get_trading_profile_by_user/2" do
    test "returns the profile for the given user" do
      user = build_trader_user()
      profile = build_trading_profile(%{user_id: user.id})

      {:ok, found} = Accounts.get_trading_profile_by_user(user.id, authorize?: false)

      assert found.id == profile.id
    end

    test "returns nil when no profile exists" do
      user = build_trader_user()

      assert {:ok, nil} = Accounts.get_trading_profile_by_user(user.id, authorize?: false)
    end
  end

  describe "User.trading_profile (has_one)" do
    test "loads when present" do
      user = build_trader_user()
      profile = build_trading_profile(%{user_id: user.id})

      {:ok, loaded} =
        Ash.get(LongOrShort.Accounts.User, user.id,
          load: [:trading_profile],
          authorize?: false
        )

      assert loaded.trading_profile.id == profile.id
    end

    test "loads as nil when absent" do
      user = build_trader_user()

      {:ok, loaded} =
        Ash.get(LongOrShort.Accounts.User, user.id,
          load: [:trading_profile],
          authorize?: false
        )

      assert is_nil(loaded.trading_profile)
    end
  end

  describe "policies" do
    setup do
      user = build_trader_user()
      profile = build_trading_profile(%{user_id: user.id})
      {:ok, user: user, profile: profile}
    end

    test "system actor can create" do
      other = build_trader_user()

      assert {:ok, _} =
               Accounts.create_trading_profile(
                 valid_trading_profile_attrs(%{user_id: other.id}),
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can create" do
      admin = build_admin_user()
      other = build_trader_user()

      assert {:ok, _} =
               Accounts.create_trading_profile(
                 valid_trading_profile_attrs(%{user_id: other.id}),
                 actor: admin
               )
    end

    test "trader can create their own profile" do
      trader = build_trader_user()

      assert {:ok, _} =
               Accounts.create_trading_profile(
                 valid_trading_profile_attrs(%{user_id: trader.id}),
                 actor: trader
               )
    end

    test "trader can upsert their own profile" do
      trader = build_trader_user()

      assert {:ok, _} =
               Accounts.upsert_trading_profile(
                 valid_trading_profile_attrs(%{user_id: trader.id}),
                 actor: trader
               )
    end

    test "trader can read their own profile" do
      trader = build_trader_user()
      _profile = build_trading_profile(%{user_id: trader.id})

      assert {:ok, %{user_id: user_id}} =
               Accounts.get_trading_profile_by_user(trader.id, actor: trader)

      assert user_id == trader.id
    end

    test "nil actor sees nil read", %{user: user} do
      assert {:ok, nil} =
               Accounts.get_trading_profile_by_user(user.id, actor: nil)
    end

    # LON-139 regression tests — ownership scoping.

    test "trader cannot create a profile for another user (validation error)" do
      trader = build_trader_user()
      other = build_trader_user()

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.create_trading_profile(
                 valid_trading_profile_attrs(%{user_id: other.id}),
                 actor: trader
               )
    end

    test "trader cannot upsert a profile for another user (validation error)" do
      trader = build_trader_user()
      other = build_trader_user()

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.upsert_trading_profile(
                 valid_trading_profile_attrs(%{user_id: other.id}),
                 actor: trader
               )
    end

    test "trader passing another user's id to get_by_user sees nil (filter semantics)", %{
      profile: profile
    } do
      trader = build_trader_user()

      # The setup `profile` belongs to a different trader. Filter-style
      # read policy: mismatched argument yields nil, not Forbidden.
      assert {:ok, nil} =
               Accounts.get_trading_profile_by_user(profile.user_id, actor: trader)
    end
  end

  # NOTE: `on_delete: :restrict` test deferred — User has no destroy
  # action defined (only `defaults [:read]`) and Accounts has no
  # `destroy_user` code interface. The FK constraint is enforced at
  # the DB level (migration: `on_delete: :restrict`) and will fire
  # the moment any User destroy path is added. LON-15 will likely
  # introduce that path.
end
