defmodule Hyperliquid.WebSocket.Manager.RecoveryTest do
  use ExUnit.Case, async: false

  alias Hyperliquid.WebSocket.Manager.Subscription

  defmodule FakeConnection do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      key = Keyword.fetch!(opts, :key)

      GenServer.start_link(__MODULE__, opts,
        name: {:via, Registry, {Hyperliquid.WebSocket.Registry, key}}
      )
    end

    def get_calls(pid), do: GenServer.call(pid, :get_calls)

    @impl true
    def init(opts) do
      {:ok, %{key: Keyword.fetch!(opts, :key), calls: []}}
    end

    @impl true
    def handle_call({:subscribe, request, sub_id}, _from, state) do
      {:reply, :ok, %{state | calls: state.calls ++ [{:subscribe, request, sub_id}]}}
    end

    def handle_call({:unsubscribe, sub_id}, _from, state) do
      {:reply, :ok, %{state | calls: state.calls ++ [{:unsubscribe, sub_id}]}}
    end

    def handle_call(:get_calls, _from, state) do
      {:reply, state.calls, state}
    end

    def handle_call(:status, _from, state) do
      {:reply,
       %{key: state.key, status: :connected, subscriptions: 0, reconnect_attempts: 0}, state}
    end
  end

  setup do
    # Use the application-started Manager. Clean its state between tests.
    manager = Process.whereis(Hyperliquid.WebSocket.Manager)
    assert manager != nil, "Manager must be running (started by application supervision tree)"

    # Reset Manager state to clean baseline
    :sys.replace_state(manager, fn state ->
      %{state | connections: %{}, subscriptions: %{}, counter: 0, zombie_check_ref: nil}
    end)

    # Clean ETS table
    if :ets.whereis(:ws_subscriptions) != :undefined do
      :ets.delete_all_objects(:ws_subscriptions)
    end

    # Unregister any leftover "shared" key from previous test runs
    case Registry.lookup(Hyperliquid.WebSocket.Registry, "shared") do
      [{pid, _}] ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        Process.sleep(10)

      [] ->
        :ok
    end

    %{manager: manager}
  end

  describe "connection recovery on :DOWN" do
    test "recovers subscriptions via Registry lookup", %{manager: manager} do
      # 1. Create a fake "old" connection (just a process that will die)
      old_pid = spawn(fn -> Process.sleep(:infinity) end)

      # 2. Start a FakeConnection registered under "shared" in the Registry
      {:ok, new_pid} = FakeConnection.start_link(key: "shared")
      on_exit(fn -> if Process.alive?(new_pid), do: GenServer.stop(new_pid) end)

      test_pid = self()

      # 3. Set Manager state to have the old connection + subscriptions
      :sys.replace_state(manager, fn state ->
        subs = %{
          "sub_1" => %Subscription{
            id: "sub_1",
            module: Hyperliquid.Api.Subscription.Candle,
            params: %{coin: "BTC", interval: "1h"},
            key: "shared",
            connection_type: :shared,
            connection_pid: old_pid,
            callback: fn msg -> send(test_pid, {:callback_1, msg}) end,
            subscribed_at: DateTime.utc_now()
          },
          "sub_2" => %Subscription{
            id: "sub_2",
            module: Hyperliquid.Api.Subscription.Candle,
            params: %{coin: "BTC", interval: "4h"},
            key: "shared",
            connection_type: :shared,
            connection_pid: old_pid,
            callback: fn msg -> send(test_pid, {:callback_2, msg}) end,
            subscribed_at: DateTime.utc_now()
          }
        }

        # Also insert into ETS
        Enum.each(subs, fn {id, sub} -> :ets.insert(:ws_subscriptions, {id, sub}) end)

        %{state | connections: %{"shared" => old_pid}, subscriptions: subs}
      end)

      # 4. Send {:DOWN} for old_pid
      send(manager, {:DOWN, make_ref(), :process, old_pid, :killed})

      # 5. Force mailbox flush
      :sys.get_state(manager)

      # 6. Assert recovery -- Manager should find new_pid via Registry and re-subscribe
      state = :sys.get_state(manager)

      assert state.connections["shared"] == new_pid
      assert state.subscriptions["sub_1"].connection_pid == new_pid
      assert state.subscriptions["sub_2"].connection_pid == new_pid

      # FakeConnection should have received 2 subscribe calls
      calls = FakeConnection.get_calls(new_pid)
      assert length(calls) == 2

      # ETS should be updated
      [{_, ets_sub1}] = :ets.lookup(:ws_subscriptions, "sub_1")
      assert ets_sub1.connection_pid == new_pid
      [{_, ets_sub2}] = :ets.lookup(:ws_subscriptions, "sub_2")
      assert ets_sub2.connection_pid == new_pid
    end

    test "messages route to callback after recovery", %{manager: manager} do
      old_pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, new_pid} = FakeConnection.start_link(key: "shared")
      on_exit(fn -> if Process.alive?(new_pid), do: GenServer.stop(new_pid) end)

      test_pid = self()

      :sys.replace_state(manager, fn state ->
        subs = %{
          "sub_1" => %Subscription{
            id: "sub_1",
            module: Hyperliquid.Api.Subscription.Candle,
            params: %{coin: "BTC", interval: "1h"},
            key: "shared",
            connection_type: :shared,
            connection_pid: old_pid,
            callback: fn msg -> send(test_pid, {:got_it, msg}) end,
            subscribed_at: DateTime.utc_now()
          }
        }

        Enum.each(subs, fn {id, sub} -> :ets.insert(:ws_subscriptions, {id, sub}) end)
        %{state | connections: %{"shared" => old_pid}, subscriptions: subs}
      end)

      # Trigger recovery
      send(manager, {:DOWN, make_ref(), :process, old_pid, :killed})
      :sys.get_state(manager)

      # Send a message as if from the new connection
      msg = %{"channel" => "candle", "data" => %{"t" => 123, "s" => "BTC", "i" => "1h"}}
      send(manager, {:ws_message, new_pid, msg})
      :sys.get_state(manager)

      # Callback should have been invoked
      assert_receive {:got_it, ^msg}, 1000
    end

    test "unknown PID is a no-op", %{manager: manager} do
      state_before = :sys.get_state(manager)

      unknown_pid = spawn(fn -> :ok end)
      send(manager, {:DOWN, make_ref(), :process, unknown_pid, :killed})

      state_after = :sys.get_state(manager)
      assert state_after.connections == state_before.connections
      assert state_after.subscriptions == state_before.subscriptions
    end

    test "no affected subs cleans up connection only", %{manager: manager} do
      old_pid = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(manager, fn state ->
        %{state | connections: %{"shared" => old_pid}, subscriptions: %{}}
      end)

      send(manager, {:DOWN, make_ref(), :process, old_pid, :killed})
      :sys.get_state(manager)

      state = :sys.get_state(manager)
      assert state.connections == %{}
      assert state.subscriptions == %{}
    end
  end

  describe "start_connection race handling" do
    test "subscribe succeeds when connection already exists in Registry", %{manager: manager} do
      # Pre-register a FakeConnection under "shared" key in the Registry
      {:ok, fake_pid} = FakeConnection.start_link(key: "shared")
      on_exit(fn -> if Process.alive?(fake_pid), do: GenServer.stop(fake_pid) end)

      test_pid = self()

      # Subscribe to a Candle -- Manager will try to create connection for key "shared".
      # Since FakeConnection already occupies "shared" in Registry, the real
      # Connection.start_link will fail with {:error, {:already_started, fake_pid}}.
      # Before fix: returns {:error, {:connection_failed, {:already_started, fake_pid}}}
      # After fix: returns {:ok, sub_id}
      result =
        GenServer.call(
          manager,
          {:subscribe, Hyperliquid.Api.Subscription.Candle, %{coin: "BTC", interval: "1h"},
           fn msg -> send(test_pid, msg) end}
        )

      assert {:ok, _sub_id} = result

      state = :sys.get_state(manager)
      # The connection should be the FakeConnection
      assert state.connections["shared"] == fake_pid
    end
  end

  describe "zombie connection watchdog" do
    test "zombie check kills connection with stale subscriptions", %{manager: manager} do
      Application.put_env(:hyperliquid, :zombie_connection_threshold_ms, 100)
      on_exit(fn -> Application.delete_env(:hyperliquid, :zombie_connection_threshold_ms) end)

      # Spawn a "zombie" process
      zombie_pid = spawn(fn -> Process.sleep(:infinity) end)
      zombie_ref = Process.monitor(zombie_pid)

      # Inject a stale subscription pointing to the zombie
      :sys.replace_state(manager, fn state ->
        subs = %{
          "sub_zombie" => %Subscription{
            id: "sub_zombie",
            module: Hyperliquid.Api.Subscription.Candle,
            params: %{coin: "BTC", interval: "1h"},
            key: "shared",
            connection_type: :shared,
            connection_pid: zombie_pid,
            callback: fn _msg -> :ok end,
            subscribed_at: DateTime.utc_now(),
            last_message_at: DateTime.add(DateTime.utc_now(), -1, :second)
          }
        }

        %{state | connections: %{"shared" => zombie_pid}, subscriptions: subs}
      end)

      # Trigger zombie check
      send(manager, :zombie_check)
      # Wait for async processing
      Process.sleep(200)

      # The zombie should be dead
      assert_receive {:DOWN, ^zombie_ref, :process, ^zombie_pid, :zombie_detected}, 1000
    end

    test "zombie check skips healthy connections", %{manager: manager} do
      Application.put_env(:hyperliquid, :zombie_connection_threshold_ms, 100)
      on_exit(fn -> Application.delete_env(:hyperliquid, :zombie_connection_threshold_ms) end)

      healthy_pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(healthy_pid), do: Process.exit(healthy_pid, :kill) end)

      :sys.replace_state(manager, fn state ->
        subs = %{
          "sub_healthy" => %Subscription{
            id: "sub_healthy",
            module: Hyperliquid.Api.Subscription.Candle,
            params: %{coin: "BTC", interval: "1h"},
            key: "shared",
            connection_type: :shared,
            connection_pid: healthy_pid,
            callback: fn _msg -> :ok end,
            subscribed_at: DateTime.utc_now(),
            last_message_at: DateTime.utc_now()
          }
        }

        %{state | connections: %{"shared" => healthy_pid}, subscriptions: subs}
      end)

      send(manager, :zombie_check)
      Process.sleep(200)

      assert Process.alive?(healthy_pid), "healthy connection should not be killed"
    end

    test "zombie check disabled when threshold is nil", %{manager: manager} do
      Application.delete_env(:hyperliquid, :zombie_connection_threshold_ms)

      state = :sys.get_state(manager)
      assert state[:zombie_check_ref] == nil, "zombie check should not be scheduled when threshold is nil"
    end

    test "zombie check skips subscriptions without callbacks", %{manager: manager} do
      Application.put_env(:hyperliquid, :zombie_connection_threshold_ms, 100)
      on_exit(fn -> Application.delete_env(:hyperliquid, :zombie_connection_threshold_ms) end)

      no_callback_pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(no_callback_pid), do: Process.exit(no_callback_pid, :kill) end)

      :sys.replace_state(manager, fn state ->
        subs = %{
          "sub_no_cb" => %Subscription{
            id: "sub_no_cb",
            module: Hyperliquid.Api.Subscription.Candle,
            params: %{coin: "BTC", interval: "1h"},
            key: "shared",
            connection_type: :shared,
            connection_pid: no_callback_pid,
            callback: nil,
            subscribed_at: DateTime.utc_now(),
            last_message_at: DateTime.add(DateTime.utc_now(), -1, :second)
          }
        }

        %{state | connections: %{"shared" => no_callback_pid}, subscriptions: subs}
      end)

      send(manager, :zombie_check)
      Process.sleep(200)

      assert Process.alive?(no_callback_pid), "should not kill connection with only nil-callback subs"
    end
  end
end
