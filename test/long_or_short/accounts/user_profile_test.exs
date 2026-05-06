defmodule LongOrShort.Accounts.UserProfileTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.AccountsFixtures

  alias LongOrShort.Accounts

  describe "create_user_profile/2" do
    test "creates a profile with valid attrs" do
      user = build_trader_user()
      attrs = valid_user_profile_attrs(%{user_id: user.id})

      {:ok, profile} = Accounts.create_user_profile(attrs, authorize?: false)

      assert profile.user_id == user.id
      assert profile.full_name == "Test Trader"
      assert profile.phone == "555-0100"
      assert profile.avatar_url == "https://example.com/avatar.png"
    end

    test "all personal fields are optional" do
      user = build_trader_user()

      {:ok, profile} =
        Accounts.create_user_profile(%{user_id: user.id}, authorize?: false)

      assert profile.user_id == user.id
      assert is_nil(profile.full_name)
      assert is_nil(profile.phone)
      assert is_nil(profile.avatar_url)
    end
  end

  describe "unique_user identity" do
    test "second :create with same user_id is rejected" do
      user = build_trader_user()
      _first = build_user_profile(%{user_id: user.id})

      attrs = valid_user_profile_attrs(%{user_id: user.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.create_user_profile(attrs, authorize?: false)
    end
  end

  describe "upsert_user_profile/2" do
    test "first call inserts, second call with same user_id updates the same row" do
      user = build_trader_user()

      {:ok, first} =
        Accounts.upsert_user_profile(
          valid_user_profile_attrs(%{user_id: user.id, full_name: "First Name"}),
          authorize?: false
        )

      {:ok, second} =
        Accounts.upsert_user_profile(
          valid_user_profile_attrs(%{
            user_id: user.id,
            full_name: "Second Name",
            phone: "555-9999"
          }),
          authorize?: false
        )

      assert second.id == first.id
      assert second.full_name == "Second Name"
      assert second.phone == "555-9999"
    end
  end

  describe "get_user_profile_by_user/2" do
    test "returns the profile for the given user" do
      user = build_trader_user()
      profile = build_user_profile(%{user_id: user.id})

      {:ok, found} = Accounts.get_user_profile_by_user(user.id, authorize?: false)

      assert found.id == profile.id
    end

    test "returns nil when no profile exists" do
      user = build_trader_user()

      assert {:ok, nil} = Accounts.get_user_profile_by_user(user.id, authorize?: false)
    end
  end

  describe "User.user_profile (has_one)" do
    test "loads when present" do
      user = build_trader_user()
      profile = build_user_profile(%{user_id: user.id})

      {:ok, loaded} =
        Ash.get(LongOrShort.Accounts.User, user.id,
          load: [:user_profile],
          authorize?: false
        )

      assert loaded.user_profile.id == profile.id
    end

    test "loads as nil when absent" do
      user = build_trader_user()

      {:ok, loaded} =
        Ash.get(LongOrShort.Accounts.User, user.id,
          load: [:user_profile],
          authorize?: false
        )

      assert is_nil(loaded.user_profile)
    end

    # NOTE: cascade delete test deferred — User has no destroy action
    # defined (only `defaults [:read]`) and Accounts has no
    # `destroy_user` code interface. The FK constraint is enforced at
    # the DB level (migration: `on_delete: :delete_all`) and will fire
    # the moment any User destroy path is added. LON-15 will likely
    # introduce that path.
  end

  describe "policies" do
    setup do
      user = build_trader_user()
      profile = build_user_profile(%{user_id: user.id})
      {:ok, user: user, profile: profile}
    end

    test "system actor can create" do
      other = build_trader_user()

      assert {:ok, _} =
               Accounts.create_user_profile(
                 valid_user_profile_attrs(%{user_id: other.id}),
                 actor: LongOrShort.Accounts.SystemActor.new()
               )
    end

    test "admin can create" do
      admin = build_admin_user()
      other = build_trader_user()

      assert {:ok, _} =
               Accounts.create_user_profile(
                 valid_user_profile_attrs(%{user_id: other.id}),
                 actor: admin
               )
    end

    test "trader CAN create — Phase 1 single-user, LON-15 will tighten" do
      trader = build_trader_user()
      other = build_trader_user()

      assert {:ok, _} =
               Accounts.create_user_profile(
                 valid_user_profile_attrs(%{user_id: other.id}),
                 actor: trader
               )
    end

    test "trader can upsert" do
      trader = build_trader_user()
      other = build_trader_user()

      assert {:ok, _} =
               Accounts.upsert_user_profile(
                 valid_user_profile_attrs(%{user_id: other.id}),
                 actor: trader
               )
    end

    test "trader can read profiles", %{profile: profile} do
      trader = build_trader_user()

      {:ok, found} =
        Accounts.get_user_profile_by_user(profile.user_id, actor: trader)

      assert found.id == profile.id
    end

    test "nil actor sees nil read", %{user: user} do
      assert {:ok, nil} =
               Accounts.get_user_profile_by_user(user.id, actor: nil)
    end
  end
end
