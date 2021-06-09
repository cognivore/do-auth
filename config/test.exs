use Mix.Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :do_auth, DoAuth.Repo,
  database: "do_auth_repo",
  hostname: "localhost",
  port: 5666

config :do_auth, DoAuth.Web,
  url: [host: "localhost"],
  http: [port: 8666]

config :do_auth, DoAuth.Repo, database: "do_auth_test", pool: Ecto.Adapters.SQL.Sandbox

import_config("test.non-secret.exs")

config :logger, level: :warn
