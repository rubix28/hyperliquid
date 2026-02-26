defmodule Hyperliquid.WebSocket.Connection do
  @moduledoc """
  WebSocket connection handler with automatic reconnection.

  Manages a single WebSocket connection to Hyperliquid, handling:
  - Connection establishment and authentication
  - Subscription management
  - Message routing
  - Automatic reconnection with exponential backoff

  ## Usage

  Typically managed by `Hyperliquid.WebSocket.Manager`, but can be used directly:

      {:ok, pid} = Connection.start_link(
        key: "l2Book:BTC:5",
        manager: manager_pid,
        url: "wss://api.hyperliquid.xyz/ws"
      )

      # Subscribe
      Connection.subscribe(pid, %{type: "l2Book", coin: "BTC", nSigFigs: 5}, "sub_123")

      # Unsubscribe
      Connection.unsubscribe(pid, "sub_123")
  """

  use GenServer
  require Logger

  @default_url "wss://api.hyperliquid.xyz/ws"
  @heartbeat_interval 30_000
  @reconnect_delays [1_000, 2_000, 5_000, 10_000, 30_000, 60_000]

  defmodule State do
    @moduledoc false
    defstruct [
      :key,
      :manager,
      :url,
      :conn,
      :stream_ref,
      :subscriptions,
      :reconnect_attempts,
      :heartbeat_ref,
      :status,
      pending_subscriptions: %{}
    ]
  end

  # ===================== Client API =====================

  @doc """
  Start a WebSocket connection.

  ## Options

  - `:key` - Required. Connection identifier
  - `:manager` - Required. Manager PID for message routing
  - `:url` - WebSocket URL (default: #{@default_url})
  """
  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(key))
  end

  @doc """
  Subscribe to a channel on this connection.
  """
  @spec subscribe(pid() | String.t(), map(), String.t()) :: :ok | {:error, term()}
  def subscribe(connection, request, subscription_id) when is_pid(connection) do
    GenServer.call(connection, {:subscribe, request, subscription_id})
  end

  def subscribe(key, request, subscription_id) when is_binary(key) do
    case lookup(key) do
      {:ok, pid} -> subscribe(pid, request, subscription_id)
      error -> error
    end
  end

  @doc """
  Unsubscribe from a channel.
  """
  @spec unsubscribe(pid() | String.t(), String.t()) :: :ok
  def unsubscribe(connection, subscription_id) when is_pid(connection) do
    GenServer.call(connection, {:unsubscribe, subscription_id})
  end

  def unsubscribe(key, subscription_id) when is_binary(key) do
    case lookup(key) do
      {:ok, pid} -> unsubscribe(pid, subscription_id)
      error -> error
    end
  end

  @doc """
  Get connection status.
  """
  @spec status(pid() | String.t()) :: map()
  def status(connection) when is_pid(connection) do
    GenServer.call(connection, :status)
  end

  def status(key) when is_binary(key) do
    case lookup(key) do
      {:ok, pid} -> status(pid)
      error -> error
    end
  end

  @doc """
  Lookup connection by key.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(key) do
    case Registry.lookup(Hyperliquid.WebSocket.Registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # ===================== Server Callbacks =====================

  @impl true
  def init(opts) do
    key = Keyword.fetch!(opts, :key)
    manager = Keyword.fetch!(opts, :manager)
    url = Keyword.get(opts, :url, @default_url)

    state = %State{
      key: key,
      manager: manager,
      url: url,
      subscriptions: %{},
      reconnect_attempts: 0,
      status: :disconnected
    }

    # Connect asynchronously
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, request, subscription_id}, _from, state) do
    # Store subscription
    subscriptions = Map.put(state.subscriptions, subscription_id, request)
    # Track as pending until we get a subscriptionResponse
    pending_subscriptions = Map.put(state.pending_subscriptions, subscription_id, request)
    state = %{state | subscriptions: subscriptions, pending_subscriptions: pending_subscriptions}

    # Send to WebSocket if connected
    result =
      if state.status == :connected do
        send_message(state, %{method: "subscribe", subscription: request})
      else
        :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      request ->
        # Remove from subscriptions
        subscriptions = Map.delete(state.subscriptions, subscription_id)
        state = %{state | subscriptions: subscriptions}

        # Send unsubscribe if connected
        if state.status == :connected do
          send_message(state, %{method: "unsubscribe", subscription: request})
        end

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      key: state.key,
      status: state.status,
      subscriptions: map_size(state.subscriptions),
      reconnect_attempts: state.reconnect_attempts
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:connect, state) do
    connect_start = System.monotonic_time()

    :telemetry.execute(
      [:hyperliquid, :ws, :connect, :start],
      %{system_time: System.system_time()},
      %{key: state.key}
    )

    case connect(state.url) do
      {:ok, conn, stream_ref} ->
        duration = System.monotonic_time() - connect_start

        :telemetry.execute(
          [:hyperliquid, :ws, :connect, :stop],
          %{duration: duration},
          %{key: state.key}
        )

        Logger.debug("WebSocket connected: #{state.key}")

        # Schedule heartbeat
        heartbeat_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)

        state = %{
          state
          | conn: conn,
            stream_ref: stream_ref,
            status: :upgrading,
            reconnect_attempts: 0,
            heartbeat_ref: heartbeat_ref
        }

        # Wait for gun_upgrade message before resubscribing
        {:noreply, state}

      {:error, reason} ->
        duration = System.monotonic_time() - connect_start

        :telemetry.execute(
          [:hyperliquid, :ws, :connect, :exception],
          %{duration: duration},
          %{key: state.key, reason: reason}
        )

        Logger.warning("WebSocket connection failed (#{state.key}): #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    if state.status == :connected do
      send_message(state, %{method: "ping"})
      heartbeat_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval)
      {:noreply, %{state | heartbeat_ref: heartbeat_ref}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_ws, _conn, _stream_ref, {:text, data}}, state) do
    :telemetry.execute(
      [:hyperliquid, :ws, :message, :received],
      %{count: 1},
      %{key: state.key}
    )

    case Jason.decode(data) do
      {:ok, message} ->
        handle_ws_message(message, state)

      {:error, reason} ->
        Logger.warning("Failed to decode WebSocket message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:gun_ws, _conn, _stream_ref, {:close, code, reason}}, state) do
    Logger.debug("WebSocket closed (#{state.key}): #{code} - #{reason}")
    handle_disconnect(state)
  end

  @impl true
  def handle_info({:gun_down, _conn, _protocol, reason, _killed}, state) do
    Logger.warning("WebSocket down (#{state.key}): #{inspect(reason)}")
    handle_disconnect(state)
  end

  @impl true
  def handle_info({:gun_error, _conn, _stream_ref, reason}, state) do
    Logger.error("WebSocket error (#{state.key}): #{inspect(reason)}")
    handle_disconnect(state)
  end

  @impl true
  def handle_info({:gun_upgrade, _conn, _stream_ref, ["websocket"], _headers}, state) do
    Logger.debug("WebSocket upgrade complete: #{state.key}")

    # Now we can set status to connected and resubscribe
    state = %{state | status: :connected}
    resubscribe_all(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_up, _conn, _protocol}, state) do
    # Gun connection established (before WS upgrade) — handled via :gun_upgrade
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Connection terminating (#{state.key}): #{inspect(reason)}")

    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    if state.conn do
      :gun.close(state.conn)
    end

    :ok
  end

  # ===================== Private Functions =====================

  defp via_tuple(key) do
    {:via, Registry, {Hyperliquid.WebSocket.Registry, key}}
  end

  defp connect(url) do
    uri = URI.parse(url)
    host = String.to_charlist(uri.host)
    port = uri.port || 443

    opts = %{
      protocols: [:http],
      transport: :tls,
      # Disable gun's built-in retry — we manage reconnection ourselves
      retry: 0,
      tls_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }

    case :gun.open(host, port, opts) do
      {:ok, conn} ->
        case :gun.await_up(conn, 5_000) do
          {:ok, _protocol} ->
            path = uri.path || "/"
            stream_ref = :gun.ws_upgrade(conn, path)
            {:ok, conn, stream_ref}

          {:error, reason} ->
            :gun.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_message(%State{conn: conn, stream_ref: stream_ref}, message)
       when not is_nil(conn) and not is_nil(stream_ref) do
    case Jason.encode(message) do
      {:ok, json} ->
        :gun.ws_send(conn, stream_ref, {:text, json})
        :ok

      {:error, reason} ->
        {:error, {:json_encode, reason}}
    end
  end

  defp send_message(_state, _message), do: {:error, :not_connected}

  defp handle_ws_message(%{"channel" => "subscriptionResponse", "data" => data} = msg, state) do
    Logger.debug("Subscription response: #{inspect(msg)}")

    # Clear pending subscriptions that match this response
    pending_subscriptions =
      state.pending_subscriptions
      |> Enum.reject(fn {_id, req} ->
        # Match if subscription type and key fields match
        matches_response?(req, data)
      end)
      |> Map.new()

    {:noreply, %{state | pending_subscriptions: pending_subscriptions}}
  end

  defp handle_ws_message(%{"channel" => "subscriptionResponse"} = msg, state) do
    Logger.debug("Subscription response: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_ws_message(%{"channel" => "error", "data" => error_msg} = message, state) do
    # Check if this is an "Already subscribed" error - these are non-fatal
    if String.contains?(error_msg, "Already subscribed") do
      Logger.warning("WebSocket duplicate subscription from #{state.key}: #{error_msg}")
      # Don't fail any subscriptions - the subscription is already active on the server
      # Just clear pending subscriptions since they're already subscribed
      {:noreply, %{state | pending_subscriptions: %{}}}
    else
      Logger.error("WebSocket error from #{state.key}: #{error_msg}")

      # For other errors, try to match specific subscription if possible
      # Currently we fail all pending subscriptions since we can't reliably match them
      failed_sub_ids = Map.keys(state.pending_subscriptions)

      # Notify manager to remove failed subscriptions
      if state.manager && Process.alive?(state.manager) do
        send(state.manager, {:ws_error, self(), message, failed_sub_ids})
      end

      # Clear pending subscriptions
      {:noreply, %{state | pending_subscriptions: %{}}}
    end
  end

  defp handle_ws_message(%{"channel" => "pong"}, state) do
    {:noreply, state}
  end

  defp handle_ws_message(%{"channel" => _channel, "data" => _data} = message, state) do
    # Route message to manager
    if state.manager && Process.alive?(state.manager) do
      send(state.manager, {:ws_message, self(), message})
    end

    {:noreply, state}
  end

  defp handle_ws_message(message, state) do
    # Unknown message format, still route to manager
    if state.manager && Process.alive?(state.manager) do
      send(state.manager, {:ws_message, self(), message})
    end

    {:noreply, state}
  end

  defp handle_disconnect(%State{status: status} = state)
       when status in [:disconnected, :reconnecting] do
    # Already handling disconnect — avoid duplicate reconnect scheduling
    {:noreply, state}
  end

  defp handle_disconnect(state) do
    :telemetry.execute(
      [:hyperliquid, :ws, :disconnect],
      %{},
      %{key: state.key}
    )

    # Cancel heartbeat
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    # Close connection if still open
    if state.conn do
      :gun.close(state.conn)
    end

    state = %{state | conn: nil, stream_ref: nil, status: :disconnected, heartbeat_ref: nil}

    schedule_reconnect(state)
  end

  defp schedule_reconnect(state) do
    delay = Enum.at(@reconnect_delays, state.reconnect_attempts, List.last(@reconnect_delays))

    Logger.debug("Scheduling reconnect in #{delay}ms (attempt #{state.reconnect_attempts + 1})")

    Process.send_after(self(), :reconnect, delay)

    {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1, status: :reconnecting}}
  end

  defp resubscribe_all(state) do
    Enum.each(state.subscriptions, fn {_id, request} ->
      send_message(state, %{method: "subscribe", subscription: request})
    end)
  end

  defp matches_response?(request, response) do
    # Match if subscription type matches
    request_type = request["type"] || request[:type]
    response_type = response["type"] || response[:type]

    if request_type != response_type do
      false
    else
      # For subscriptions with parameters, match key fields
      # This is a simple match - we compare all fields in the response
      Enum.all?(response, fn {key, value} ->
        request[key] == value || request[String.to_atom(key)] == value
      end)
    end
  end
end
