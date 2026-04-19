defmodule LongOrShort.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        LongOrShort.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:long_or_short, :token_signing_secret)
  end
end
