defmodule LongOrShort.Settings.SettingTest do
  @moduledoc """
  Tests for the `LongOrShort.Settings.Setting` Ash resource — LON-125.

  Covers identity uniqueness, the `:type` enum constraint, the
  `:by_key` read action, and the policy surface (SystemActor /
  `:admin` allowed; `:trader` / anonymous forbidden).
  """

  use LongOrShort.DataCase, async: true

  import LongOrShort.AccountsFixtures

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Settings

  defp seed!(attrs \\ %{}) do
    base = %{
      key: "test_key_#{System.unique_integer([:positive])}",
      value: "180",
      type: :integer,
      description: "test"
    }

    Settings.create_setting!(Map.merge(base, attrs), actor: SystemActor.new())
  end

  describe "create" do
    test "creates a setting with valid attrs" do
      assert {:ok, setting} =
               Settings.create_setting(
                 %{
                   key: "dilution_profile_window_days",
                   value: "180",
                   type: :integer,
                   description: "window days for dilution profile"
                 },
                 actor: SystemActor.new()
               )

      assert setting.key == "dilution_profile_window_days"
      assert setting.type == :integer
      assert setting.value == "180"
      assert setting.description =~ "window days"
    end

    test "rejects duplicate :key via the :unique_key identity" do
      seed!(%{key: "duplicate"})

      assert {:error, _} =
               Settings.create_setting(
                 %{key: "duplicate", value: "x", type: :string},
                 actor: SystemActor.new()
               )
    end

    test "rejects :type outside the enum" do
      assert {:error, _} =
               Settings.create_setting(
                 %{key: "bad_type", value: "1", type: :not_a_real_type},
                 actor: SystemActor.new()
               )
    end

    test "stores all five supported types" do
      for type <- [:integer, :decimal, :boolean, :atom, :string] do
        unique_key = "type_test_#{type}"

        assert {:ok, s} =
                 Settings.create_setting(
                   %{key: unique_key, value: "v", type: type},
                   actor: SystemActor.new()
                 )

        assert s.type == type
      end
    end
  end

  describe "by_key" do
    test "returns the matching row" do
      seed!(%{key: "findable"})
      assert %{key: "findable"} = Settings.get_setting_by_key!("findable", actor: SystemActor.new())
    end

    test "returns nil when no row matches (get?, not_found_error?: false)" do
      assert nil == Settings.get_setting_by_key!("missing_key", actor: SystemActor.new())
    end
  end

  describe "policies" do
    test "admin can read" do
      admin = build_admin_user()
      seed!()
      assert {:ok, [_ | _]} = Settings.list_settings(actor: admin)
    end

    test "admin can create" do
      admin = build_admin_user()

      assert {:ok, _} =
               Settings.create_setting(
                 %{key: "admin_created", value: "1", type: :integer},
                 actor: admin
               )
    end

    test "trader cannot read" do
      trader = build_trader_user()
      seed!()
      assert {:error, %Ash.Error.Forbidden{}} = Settings.list_settings(actor: trader)
    end

    test "trader cannot create" do
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Settings.create_setting(
                 %{key: "trader_blocked", value: "1", type: :integer},
                 actor: trader
               )
    end

    test "SystemActor bypasses for the Loader's read path" do
      seed!()
      assert {:ok, [_ | _]} = Settings.list_settings(actor: SystemActor.new())
    end
  end
end
