defmodule Mix.Tasks.Symphony.Tui do
  use Mix.Task

  @shortdoc "Start the terminal status dashboard without the web endpoint"

  @moduledoc """
  Starts the Symphony TUI (terminal status dashboard) without the Phoenix web endpoint.

  ## Usage

      mix symphony.tui
      mix symphony.tui --project my-project-slug

  ## Options

    * `--project` - Override the Linear project slug (alternative to `LINEAR_PROJECT_SLUG` env var)
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [project: :string])

    if project = Keyword.get(opts, :project) do
      System.put_env("LINEAR_PROJECT_SLUG", project)
    end

    Application.put_env(:symphony_elixir, :mode, :tui)

    Mix.Task.run("app.start")

    unless iex_running?() do
      Process.sleep(:infinity)
    end
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
