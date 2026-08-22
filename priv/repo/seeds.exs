if Mix.env() == :dev do
  alias Kodo.Accounts
  alias Kodo.Accounts.User
  alias Kodo.Repo

  email = "dev@kodo.local"
  password = "supersecure!"
  legacy_password = "hello world!"

  user =
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} = Accounts.register_user(%{email: email})
        user

      user ->
        user
    end

  user =
    if user.confirmed_at do
      user
    else
      user
      |> User.confirm_changeset()
      |> Repo.update!()
    end

  if is_nil(user.hashed_password) or User.valid_password?(user, legacy_password) do
    {:ok, {_user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: password})
  end
end
