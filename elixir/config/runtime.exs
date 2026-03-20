import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("PORT") || "4001")
  host = System.get_env("PHX_HOST") || "localhost"
  secret_key_base = System.get_env("SECRET_KEY_BASE") || String.duplicate("s", 64)

  config :symphony_elixir, SymphonyElixirWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true

  # Default to :web mode in production (orchestrator + web dashboard)
  config :symphony_elixir, :mode, :web
end
