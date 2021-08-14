defmodule DoAuthWeb.Users.InviteControllerTest do
  @moduledoc """
  Testing that invites work well.
  """

  use DoAuthWeb.ConnCase
  use DoAuth.DataCase
  use DoAuth.Boilerplate.DatabaseStuff
  use DoAuth.Test.Support.Fixtures, [:crypto]
  alias DoAuth.Repo.Populate
  alias DoAuth.{Crypto, Presentation}

  describe "Invite endpoint" do
    setup do
      {:ok, _} = Populate.populate_do()
      :ok
    end

    test "can be used to fulfill an invite", %{conn: c} do
      root_invite = Populate.ensure_root_invite!({}) |> Credential.to_map()
      skp = Crypto.server_keypair()

      {:ok, invite_presentation} =
        Presentation.present_credential_map(skp, root_invite, nonce: Enum.random(0..1_000_000))

      new_kp = signing_key_fixture(Enum.random(8..32))
      new_pk64 = new_kp.public |> Crypto.show()

      _fulfillment =
        post(c, "/users/invite", %{"public" => new_pk64, "invite" => invite_presentation})
    end
  end
end