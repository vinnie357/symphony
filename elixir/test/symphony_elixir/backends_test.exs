defmodule SymphonyElixir.BackendsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Backends.Claude
  alias SymphonyElixir.Backends.Gemini

  defmodule MockCmd do
    def cmd("claude", args, _opts) do
      prompt = List.last(args)
      {"Claude response to: #{prompt}", 0}
    end

    def cmd("gemini", args, _opts) do
      prompt = List.last(args)
      {"Gemini response to: #{prompt}", 0}
    end
  end

  defmodule FailingCmd do
    def cmd(_command, _args, _opts) do
      {"Error: command not found", 127}
    end
  end

  setup do
    prev = Application.get_env(:symphony_elixir, :cmd_runner)
    Application.put_env(:symphony_elixir, :cmd_runner, MockCmd)
    on_exit(fn ->
      if prev, do: Application.put_env(:symphony_elixir, :cmd_runner, prev),
      else: Application.delete_env(:symphony_elixir, :cmd_runner)
    end)
    :ok
  end

  describe "Claude backend" do
    test "start_session returns workspace session" do
      assert {:ok, %{workspace: "/tmp/test"}} =
               Claude.start_session(%{}, "/tmp/test", %{})
    end

    test "run_turn executes claude CLI and returns result" do
      {:ok, session} = Claude.start_session(%{}, "/tmp/test", %{})

      assert {:ok, result} = Claude.run_turn(session, "fix the bug", [])
      assert result.result =~ "Claude response to: fix the bug"
      assert is_binary(result.session_id)
      assert is_binary(result.turn_id)
    end

    test "run_turn calls on_message callback" do
      {:ok, session} = Claude.start_session(%{}, "/tmp/test", %{})
      test_pid = self()

      on_message = fn msg -> send(test_pid, {:message, msg}) end

      assert {:ok, _result} =
               Claude.run_turn(session, "test prompt", on_message: on_message)

      assert_received {:message, %{type: :turn_completed, output: output}}
      assert output =~ "Claude response to: test prompt"
    end

    test "run_turn returns error on CLI failure" do
      Application.put_env(:symphony_elixir, :cmd_runner, FailingCmd)

      {:ok, session} = Claude.start_session(%{}, "/tmp/test", %{})

      assert {:error, {:claude_cli_failed, 127, _}} =
               Claude.run_turn(session, "test", [])
    end

    test "stop_session is a no-op" do
      assert :ok = Claude.stop_session(%{workspace: "/tmp/test"})
    end
  end

  describe "Gemini backend" do
    test "start_session returns workspace session" do
      assert {:ok, %{workspace: "/tmp/test"}} =
               Gemini.start_session(%{}, "/tmp/test", %{})
    end

    test "run_turn executes gemini CLI and returns result" do
      {:ok, session} = Gemini.start_session(%{}, "/tmp/test", %{})

      assert {:ok, result} = Gemini.run_turn(session, "research this", [])
      assert result.result =~ "Gemini response to: research this"
      assert is_binary(result.session_id)
      assert is_binary(result.turn_id)
    end

    test "run_turn calls on_message callback" do
      {:ok, session} = Gemini.start_session(%{}, "/tmp/test", %{})
      test_pid = self()

      on_message = fn msg -> send(test_pid, {:message, msg}) end

      assert {:ok, _result} =
               Gemini.run_turn(session, "test prompt", on_message: on_message)

      assert_received {:message, %{type: :turn_completed, output: output}}
      assert output =~ "Gemini response to: test prompt"
    end

    test "run_turn returns error on CLI failure" do
      Application.put_env(:symphony_elixir, :cmd_runner, FailingCmd)

      {:ok, session} = Gemini.start_session(%{}, "/tmp/test", %{})

      assert {:error, {:gemini_cli_failed, 127, _}} =
               Gemini.run_turn(session, "test", [])
    end

    test "stop_session is a no-op" do
      assert :ok = Gemini.stop_session(%{workspace: "/tmp/test"})
    end
  end
end
