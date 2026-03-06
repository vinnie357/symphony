defmodule Mix.Tasks.Symphony.Web do
  use Mix.Task

  @shortdoc "Start the Phoenix web dashboard without the TUI"

  @moduledoc """
  Starts the Symphony Phoenix web dashboard only (no TUI, no orchestrator polling loop).

  ## Usage

      mix symphony.web
      mix symphony.web --port 4001

  ## Options

    * `--port` - The port to listen on (default: 4000)
  """

  @default_port 4000

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [port: :integer])
    port = Keyword.get(opts, :port, @default_port)

    Application.put_env(:symphony_elixir, :mode, :web)
    Application.put_env(:symphony_elixir, :server_port_override, port)

    Mix.Task.run("app.start")

    Mix.shell().info("Symphony web dashboard running on http://127.0.0.1:#{port}")

    unless iex_running?() do
      Process.sleep(:infinity)
    end
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
