defmodule DoAuth.Crypto do
  @moduledoc """
  Wrappers around just enough of enacl to be able to exectute both client and
  server parts of the protocol.
  """

  use DoAuth.Boilerplate.DatabaseStuff

  alias DoAuth.Cat
  alias :enacl, as: C

  @typedoc """
  Catch-all standin while https://github.com/jlouis/enacl/issues/59 gets sorted out.
  """
  @type pwhash_limit :: atom()

  @typedoc """
  Derivation limits type. Currently used in default_params function and slip
  type.
  They govern how many instructions and how much memory is allowed to be
  consumed by the system.

  """
  @type limits :: %{ops: pwhash_limit(), mem: pwhash_limit()}

  @typedoc """
  Libsodium-compatible salt size.

  Used in default_params, but NOT used in @type slip!
  If you change this parameter, you MUST change :salt, <<_ :: ...>> section
  of @type slip as well!
  Some additional safety is provided by defining a simple macro @salt_size
  below.
  """
  @type salt_size :: 16
  @salt_size 16
  @type salt :: <<_::128>>

  @typedoc """
  Hash sizes, analogously.
  """
  @type hash_size :: 32
  @hash_size 32
  @type hash :: <<_::256>>

  @typedoc """
  Main key derivation slip.
  Returned by `main_key_init`, and required for `main_key_reproduce`.
  """
  @type slip :: %{ops: pwhash_limit(), mem: pwhash_limit(), salt: salt()}

  @type params :: %{ops: pwhash_limit(), mem: pwhash_limit(), salt_size: salt_size()}

  @doc """
  Currently we use moderate limits, because we want to support small computers.
  TODO:
  Use configurable values here, based on the power of a computer.
  """
  @spec default_params :: params()
  def default_params(), do: %{ops: :moderate, mem: :moderate, salt_size: @salt_size}

  @typedoc """
  This is a keypair, marking explicitly what's private (secret) key and
  what's public key.
  """
  @type keypair :: %{secret: binary(), public: binary()}

  @typedoc """
  A keypair that maybe has its secret component omitted.
  """
  @type keypair_opt :: %{optional(:secret) => binary(), :public => binary()}

  @typedoc """
  Marked private (secret) key.
  """
  @type secret :: %{secret: binary()}

  @typedoc """
  Marked public key.
  """
  @type public :: %{public: binary()}

  @typedoc """
  Detached signature along with the public key needed to validate.
  """
  @type detached_sig :: %{public: binary(), signature: binary()}

  @typedoc """
  Only accept atoms as keys of canonicalisable entities.
  """
  @type canonicalisable_key :: atom()

  @typedoc """
  Only accept atoms, strings and numbers as values of canonocalisable entities.
  """
  @type canonicalisable_value ::
          atom()
          | String.t()
          | number()
          | DateTime.t()
          | list(canonicalisable_value())
          | %{canonicalisable_key() => canonicalisable_value()}

  @type canonicalised_value ::
          String.t() | number() | list(list(String.t() | canonicalised_value()))

  @doc """
  Generate slip and main key from password with given parameters.
  This function is used directly for testing and flexibility, but shouldn't be normally used.
  For most purposes, you should use `main_key_init/1`.
  """
  @spec main_key_init(binary() | iolist(), params()) :: {binary, slip()}
  def main_key_init(pass, %{ops: ops, mem: mem, salt_size: salt_size}) do
    salt = C.randombytes(salt_size)
    mkey = C.pwhash(pass, salt, ops, mem)
    slip = %{ops: ops, mem: mem, salt: salt}
    {mkey, slip}
  end

  @doc """
  Generate slip and main key from password.
  """
  @spec main_key_init(binary() | iolist()) :: {binary, slip()}
  def main_key_init(pass) do
    main_key_init(pass, default_params())
  end

  @doc """
  Generate main key from password and a slip.
  """
  @spec main_key_reproduce(binary() | iolist(), slip()) :: binary()
  def main_key_reproduce(pass, %{ops: ops, mem: mem, salt: salt}) do
    C.pwhash(pass, salt, ops, mem)
  end

  @doc """
  Create a signing keypair from main key at index n.
  """
  @spec derive_signing_keypair(binary(), pos_integer) :: %{public: binary, secret: binary}
  def derive_signing_keypair(mkey, n) do
    C.kdf_derive_from_key(mkey, "signsign", n) |> C.sign_seed_keypair()
  end

  @doc """
  Wrapper around detached signatures that creates an object tracking
  corresponding public key.
  """
  @spec sign(binary() | iolist(), keypair()) :: detached_sig()
  def sign(msg, %{secret: sk, public: pk}) do
    %{public: pk, signature: C.sign_detached(msg, sk)}
  end

  @doc """
  Verify a detached signature object.
  """
  @spec verify(binary() | iolist(), detached_sig()) :: boolean
  def verify(msg, %{public: pk, signature: sig}) do
    C.sign_verify_detached(sig, msg, pk)
  end

  @doc """
  Verifies a map that has a proof embedded into it by converting said object into a map, deleting embedding, canonicalising the result and verifying the result against the embedding.
  This function is configurable via options and has the following options:
   * :proof_field - which field carries the embedded proof. Defaults to "proof".
   * ignore: [] - list of fields to ignore. Defaults to ["id"].
   * :signature_field - which field carries the detached signature. Defaults to "signature".
   * :key_extractor - a function that retreives public key needed to verify embedded proof. Defaults to taking 0th element of DID.all_by_string ran against "verificationMethod" field of the proof object.
  As per https://www.w3.org/TR/vc-data-model/, proof object may be a list, this function accounts for it.
  It uses Elixir's Result / Either convention and returns either {:ok, true} or {:error, any()}. Exceptions are wrapped in :error tuple and aren't re-raised.
  """
  @spec verify_map(map(), list(), list()) :: {:error, any()} | {:ok, true}
  def verify_map(
        %{} = verifiable_map,
        overrides \\ [],
        defaults \\ [
          proof_field: "proof",
          signature_field: "signature",
          key_extractor: fn proof ->
            did_str = Map.get(proof, "verificationMethod")
            [did | _] = DID.all_by_string(did_str)
            did.key.public_key
          end,
          ignore: ["id"]
        ]
      ) do
    try do
      opts = Keyword.merge(defaults, overrides)

      verifiable_canonical =
        Enum.reduce(
          [opts[:proof_field] | opts[:ignore]],
          verifiable_map,
          fn x, acc ->
            Map.delete(acc, x)
          end
        )
        |> canonicalise_term!()

      proofs =
        case Map.get(verifiable_map, opts[:proof_field]) do
          proofs = [_ | _] -> proofs
          [] -> throw(%{"argument error" => %{"empty proof list" => verifiable_map}})
          proof -> [proof]
        end

      case Enum.reduce_while(proofs, false, fn proof, _ ->
             detached_sig =
               %{
                 public: opts[:key_extractor].(proof),
                 signature: Map.get(proof, opts[:signature_field])
               }
               |> Cat.fmap!(&read!(&1))

             is_valid = verify(verifiable_canonical |> Jason.encode!(), detached_sig)

             if is_valid do
               {:cont, true}
             else
               {:halt,
                %{
                  "signature verification failed" => %{
                    "verifiable object" => verifiable_map,
                    "canonical representation" => verifiable_canonical,
                    "detached signature" => detached_sig
                  }
                }}
             end
           end) do
        true -> {:ok, true}
        e -> {:error, e}
      end
    rescue
      e -> {:error, %{"exception" => e, "stack trace" => __STACKTRACE__}}
    end
  end

  @doc """
  Signs a map and embeds detached signature into it.
  This function is configurable via options and has the following options:
   * :proof_field - which field carries the embedded proof. Defaults to "proof".
   * :signature_field - which field of the proof carries the detached signature. Defaults to "signature".
   * :signature - if present, this function won't use :secret from keypair, but instead will add this signature verbatim. No verification shall be conducted in case the signature provided is invalid!
   * :key_field - which field of the proof stores information related to key retrieval. Defaults to "verificationMethod".
   * :key_field_constructor - a function that takes the public key and options and constructs value for :key_field, perhaps stateful. By default it queries for a DID corresponding to the key and returns its string representation.
   * :if_did_missing - if set to :insert, default key constructor will insert a new DID, otherwise will error out. By default set to :fail.
   * ignore: [] - list of fields to omit from building a canonicalised object. Defaults to ["id"].
  """
  @spec sign_map(keypair_opt(), map(), list(), list()) :: {:error, any()} | {:ok, map()}
  def sign_map(
        kp,
        the_map,
        overrides \\ [],
        defaults \\ sign_map_def_opts()
      ) do
    try do
      opts = Keyword.merge(defaults, overrides)

      to_prove =
        Enum.reduce(
          opts[:ignore],
          the_map,
          fn x, acc ->
            Map.delete(acc, x)
          end
        )

      canonical_claim = to_prove |> canonicalise_term!()
      %{signature: sig, public: pk} = canonical_claim |> Proof.canonical_sign!(kp)
      {:ok, did} = opts[:key_field_constructor].(pk, opts)
      issuer = Issuer.sin_one_did!(did)
      proof_map = Proof.from_signature64!(issuer, sig |> show()) |> Proof.to_map()
      {:ok, Map.put(to_prove, opts[:proof_field], proof_map)}
    rescue
      e -> {:error, %{"exception" => e, "stack trace" => __STACKTRACE__}}
    end
  end

  @spec sign_map!(keypair_opt(), map(), list(), list()) :: map
  def sign_map!(kp, to_prove, overrides \\ [], defopts \\ sign_map_def_opts()) do
    {:ok, res} = sign_map(kp, to_prove, overrides, defopts)
    res
  end

  @spec sign_map_def_opts :: [
          {:key_field_constructor, (any, any -> any)}
          | {:key_field, <<_::144>>}
          | {:proof_field, <<_::40>>}
          | {:signature_field, <<_::72>>},
          ...
        ]
  def sign_map_def_opts() do
    [
      proof_field: "proof",
      signature_field: "signature",
      key_field: "verificationMethod",
      key_field_constructor: fn pk, opts ->
        pk64 = pk |> show()

        case DID.all_by_pk64(pk64) do
          [did | _] ->
            {:ok, did}

          [] ->
            if opts[:if_did_missing] == :insert do
              did = DID.sin_one_pk64!(pk64)
              {:ok, did}
            else
              {:error, %{"won't insert a missing DID" => %{"pk" => pk, "opts" => opts}}}
            end
        end
      end,
      ignore: ["id"]
    ]
  end

  @doc """
  Keyed (salted) generic hash of an iolist, represented as a URL-safe Base64 string.
  The key is obtained from the application configuration's paramterer "hash_salt".
  Note: this parameter is expected to be long-lived and secret.
  Note: the hash size is crypto_generic_BYTES, manually written down as
  @hash_size macro in this file.
  """
  @spec salted_hash(binary() | iolist()) :: binary()
  def salted_hash(msg) do
    with key <- Application.get_env(:do_auth, DoAuth.Crypto) |> Keyword.fetch!(:hash_salt) do
      C.generichash(@hash_size, msg, key) |> Base.url_encode64()
    end
  end

  @doc """
  Unkeyed generic hash of an iolist, represented as a URL-safe Base64 string.
  Note: the hash size is crypto_generic_BYTES, manually written down as
  @hash_size macro in this file.
  """
  @spec bland_hash(binary() | iolist()) :: binary()
  def bland_hash(msg) do
    C.generichash(@hash_size, msg) |> Base.url_encode64()
  end

  @doc """
  Convert to URL-safe Base 64.
  """
  @spec show(binary) :: String.t()
  def show(x), do: Base.url_encode64(x)

  @doc """
  Read from URL-safe Base 64.
  """
  @spec read!(String.t()) :: binary()
  def read!(x), do: Base.url_decode64!(x)

  @doc """
  Non-exploding version of read.
  """
  @spec read(String.t()) :: {:ok, binary()} | {:error, any()}
  def read(x) do
    case Base.url_decode64(x) do
      res = {:ok, _} -> res
      :error -> {:error, %{"url_decode64 failure" => x}}
    end
  end

  @spec canonicalise_term(canonicalisable_value()) ::
          {:ok, canonicalised_value()} | {:error, any()}
  def canonicalise_term(x) do
    try do
      {:ok, canonicalise_term!(x)}
    rescue
      e -> {:error, %{"exception" => e, "stack trace" => __STACKTRACE__}}
    end
  end

  @spec is_canonicalised?(any()) :: boolean()
  def is_canonicalised?(<<_::binary>>), do: true
  def is_canonicalised?(x) when is_number(x), do: true
  def is_canonicalised?([]), do: true
  def is_canonicalised?([x | rest]), do: is_canonicalised?(x) && is_canonicalised?(rest)
  def is_canonicalised?(_), do: false

  @doc """
    Preventing canonicalisation bugs by ordering maps lexicographically into a
    list. NB! This makes it so that list representations of JSON objects are
    also accepted by verifiers, but it's OK, since no data can seemingly be
    falsified like this.

    TODO: Audit this function really well, both here and in JavaScript reference
    implementation, since a bug here can sabotage the security guarantees of the
    cryptographic system.
  """
  @spec canonicalise_term!(canonicalisable_value()) :: canonicalised_value()
  def canonicalise_term!(v) when is_binary(v) or is_number(v) do
    v
  end

  def canonicalise_term!(v) when is_atom(v) do
    Atom.to_string(v)
  end

  def canonicalise_term!(%DateTime{} = tau) do
    DateTime.to_iso8601(tau)
  end

  def canonicalise_term!([] = xs) do
    Enum.map(xs, fn v -> canonicalise_term!(v) end)
  end

  def canonicalise_term!(%{} = kv) do
    canonicalise_term_do(Map.keys(kv) |> Enum.sort(), kv, []) |> Enum.reverse()
  end

  def canonicalise_term!(xs) when is_tuple(xs) do
    canonicalise_term!(Tuple.to_list(xs))
  end

  defp canonicalise_term_do([], _, acc), do: acc

  defp canonicalise_term_do([x | rest], kv, acc) when is_atom(x) or is_binary(x) do
    x_canonicalised =
      if is_atom(x) do
        Atom.to_string(x)
      else
        x
      end

    canonicalise_term_do(rest, kv, [[x_canonicalised, canonicalise_term!(kv[x])] | acc])
  end

  @doc """
  Simple way to get the server keypair.

  # TODO: audit key management practices in Phoenix and here.
  """
  @spec server_keypair :: keypair()
  def server_keypair() do
    kp_maybe = Application.get_env(:do_auth, DoAuth.Crypto) |> Keyword.get(:server_keypair, {})

    if kp_maybe == {} do
      with slip <-
             %{
               mem: :moderate,
               ops: :moderate,
               salt: <<84, 5, 187, 21, 147, 222, 144, 242, 242, 64, 139, 14, 25, 160, 85, 88>>
             } do
        Application.get_env(:do_auth, DoAuth.Web)
        |> Keyword.get(:secret_key_base, "")
        |> main_key_reproduce(slip)
        |> derive_signing_keypair(1)
      end
    else
      kp_maybe
    end
  end

  @spec server_keypair64 :: keypair()
  def server_keypair64() do
    server_keypair() |> DoAuth.Cat.fmap!(&show(&1))
  end
end
