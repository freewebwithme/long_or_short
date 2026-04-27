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
end
