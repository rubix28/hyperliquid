defmodule Hyperliquid.WebSocket.ConnectionTest do
  use ExUnit.Case, async: false

  alias Hyperliquid.WebSocket.Connection

  # Start a connection that will fail to connect (bogus localhost URL).
  # The GenServer starts, sends itself :connect, which fails and schedules
  # a reconnect — but the process stays alive in :reconnecting state.
  defp start_disconnected_connection(key) do
    {:ok, pid} =
      Connection.start_link(
        key: key,
        manager: self(),
        url: "wss://localhost:1234"
      )

    # Let the connection attempt and fail
    Process.sleep(200)

    pid
  end

  describe "unsubscribe pending_subscriptions cleanup" do
    test "unsubscribe removes from both subscriptions and pending_subscriptions" do
      pid = start_disconnected_connection("test_unsub_both_#{System.unique_integer()}")

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      sub_id = "sub_leak_test"
      request = %{"type" => "l2Book", "coin" => "BTC", "nSigFigs" => 5}

      # Inject state: subscription exists in BOTH subscriptions and pending_subscriptions
      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :disconnected,
            subscriptions: %{sub_id => request},
            pending_subscriptions: %{sub_id => request}
        }
      end)

      # Verify setup
      state_before = :sys.get_state(pid)
      assert Map.has_key?(state_before.subscriptions, sub_id)
      assert Map.has_key?(state_before.pending_subscriptions, sub_id)

      # Unsubscribe
      assert :ok = GenServer.call(pid, {:unsubscribe, sub_id})

      # Verify both maps are cleaned
      state_after = :sys.get_state(pid)
      refute Map.has_key?(state_after.subscriptions, sub_id),
             "subscription should be removed from subscriptions"

      refute Map.has_key?(state_after.pending_subscriptions, sub_id),
             "subscription should be removed from pending_subscriptions (memory leak)"
    end

    test "unsubscribe of unknown id returns error without affecting pending" do
      pid = start_disconnected_connection("test_unsub_unknown_#{System.unique_integer()}")

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      pending_id = "pending_only"
      pending_request = %{"type" => "trades", "coin" => "ETH"}

      # Inject state: pending_subscriptions has an entry, but subscriptions does NOT
      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :disconnected,
            subscriptions: %{},
            pending_subscriptions: %{pending_id => pending_request}
        }
      end)

      # Try to unsubscribe a key that only exists in pending_subscriptions
      assert {:error, :not_found} = GenServer.call(pid, {:unsubscribe, pending_id})

      # pending_subscriptions should be untouched
      state_after = :sys.get_state(pid)
      assert state_after.pending_subscriptions == %{pending_id => pending_request},
             "pending_subscriptions should not be modified on :not_found path"
    end
  end
end
