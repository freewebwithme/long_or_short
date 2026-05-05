defmodule LongOrShort.AccountsFixtures do
  def build_admin_user do
    register_user!(%{role: :admin, email_prefix: "admin"})
  end

  def build_trader_user do
    register_user!(%{role: :trader, email_prefix: "trader"})
  end

  def register_user!(%{role: role, email_prefix: prefix}) do
    unique = System.unique_integer([:positive])
    email = "#{prefix}#{unique}@example.com"
    password = "testpassword123"

    {:ok, user} =
      LongOrShort.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: email,
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )
      |> Ash.create()

    # Set role directly — there's no public action for it yet, and the
    # Accounts domain hasn't decided how role management should work.
    # See LON-15 discussion for context.
    {:ok, user_with_role} =
      user
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:role, role)
      |> Ash.update()

    user_with_role
  end

  @doc """
  Returns a SystemActor for use in tests that need a trusted caller.
  """
  def system_actor, do: LongOrShort.Accounts.SystemActor.new("test")

  @doc """
  Default attributes for a complete TradingProfile (momentum_day persona,
  matches the values currently hardcoded in the prompt). Caller supplies
  `:user_id` separately via overrides.
  """
  def valid_trading_profile_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        trading_style: :momentum_day,
        time_horizon: :intraday,
        market_cap_focuses: [:micro, :small],
        catalyst_preferences: [:partnership, :fda, :ma, :contract_win],
        price_min: Decimal.new("2.0"),
        price_max: Decimal.new("10.0"),
        float_max: 50_000_000
      },
      overrides
    )
  end

  @doc """
  Builds a TradingProfile via the `:create` action. Lazily creates a
  trader user if `:user_id` is not supplied.
  """
  def build_trading_profile(overrides \\ %{}) do
    user_id =
      Map.get_lazy(overrides, :user_id, fn -> build_trader_user().id end)

    attrs =
      overrides
      |> Map.delete(:user_id)
      |> valid_trading_profile_attrs()
      |> Map.put(:user_id, user_id)

    case LongOrShort.Accounts.create_trading_profile(attrs, authorize?: false) do
      {:ok, profile} ->
        profile

      {:error, error} ->
        raise """
        Failed to create trading_profile fixture.
        attrs: #{inspect(attrs)}
        error: #{inspect(error)}
        """
    end
  end
end
