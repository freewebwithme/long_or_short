defmodule LongOrShort.Accounts do
  use Ash.Domain, otp_app: :long_or_short, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource LongOrShort.Accounts.Token
    resource LongOrShort.Accounts.User
  end
end
