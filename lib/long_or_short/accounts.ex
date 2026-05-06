defmodule LongOrShort.Accounts do
  use Ash.Domain, otp_app: :long_or_short, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource LongOrShort.Accounts.Token

    resource LongOrShort.Accounts.TradingProfile do
      define :create_trading_profile, action: :create
      define :upsert_trading_profile, action: :upsert

      define :get_trading_profile_by_user,
        action: :get_by_user,
        args: [:user_id],
        get?: true,
        not_found_error?: false

      define :destroy_trading_profile, action: :destroy
    end

    resource LongOrShort.Accounts.UserProfile do
      define :create_user_profile, action: :create
      define :upsert_user_profile, action: :upsert

      define :get_user_profile_by_user,
        action: :get_by_user,
        args: [:user_id],
        get?: true,
        not_found_error?: false

      define :destroy_user_profile, action: :destroy
    end

    resource LongOrShort.Accounts.User
  end
end
