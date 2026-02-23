defmodule Hyperliquid.Storage.Writer do
  @moduledoc """
  Writes subscription events to configured storage backends.

  Events are buffered and flushed periodically for efficiency. This GenServer
  provides both async (fire-and-forget) and sync (blocking) storage operations.

  ## Usage

      # Queue an event for async storage (recommended for high-throughput)
      Writer.store_async(Hyperliquid.Api.Subscription.Trades, event_data)

      # Store an event synchronously (for critical data)
      {:ok, :stored} = Writer.store_sync(module, event_data)

  ## Configuration

  The writer respects storage configuration defined in each subscription module
  via the `storage` option in `use Hyperliquid.Api.SubscriptionEndpoint`.
  """

  use GenServer
  require Logger

  @type event_entry :: {module(), map(), integer()}

  defstruct [
    :buffer,
    :timer_ref,
    :flush_interval,
    :buffer_size
  ]

  # Default flush interval (5 seconds)
  @default_flush_interval 5_000

  # Default buffer size before forcing a flush
  @default_buffer_size 100

  # ===================== Client API =====================

  @doc """
  Start the storage writer.

  ## Options

  - `:flush_interval` - Milliseconds between flushes (default: #{@default_flush_interval})
  - `:buffer_size` - Max events before forcing flush (default: #{@default_buffer_size})
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Queue an event for async storage.

  This is non-blocking and batches writes for efficiency.
  """
  @spec store_async(module(), map()) :: :ok
  def store_async(module, event_data) do
    GenServer.cast(__MODULE__, {:store, module, event_data, System.monotonic_time()})
  end

  @doc """
  Store an event synchronously.

  This blocks until the event is written to all configured backends.
  """
  @spec store_sync(module(), map()) :: {:ok, :stored} | {:error, term()}
  def store_sync(module, event_data) do
    GenServer.call(__MODULE__, {:store_sync, module, event_data})
  end

  @doc """
  Force an immediate flush of the buffer.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Get current buffer size.
  """
  @spec buffer_size() :: non_neg_integer()
  def buffer_size do
    GenServer.call(__MODULE__, :buffer_size)
  end

  # ===================== Server Callbacks =====================

  @impl true
  def init(opts) do
    flush_interval = Keyword.get(opts, :flush_interval, @default_flush_interval)
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    timer_ref = schedule_flush(flush_interval)

    {:ok,
     %__MODULE__{
       buffer: [],
       timer_ref: timer_ref,
       flush_interval: flush_interval,
       buffer_size: buffer_size
     }}
  end

  @impl true
  def handle_cast({:store, module, event_data, timestamp}, state) do
    buffer = [{module, event_data, timestamp} | state.buffer]

    # Flush if buffer is full
    state =
      if length(buffer) >= state.buffer_size do
        do_flush(buffer)
        %{state | buffer: []}
      else
        %{state | buffer: buffer}
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:store_sync, module, event_data}, _from, state) do
    result = write_to_storage(module, event_data)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    if state.buffer != [] do
      do_flush(state.buffer)
    end

    {:reply, :ok, %{state | buffer: []}}
  end

  @impl true
  def handle_call(:buffer_size, _from, state) do
    {:reply, length(state.buffer), state}
  end

  @impl true
  def handle_info(:flush, state) do
    if state.buffer != [] do
      do_flush(state.buffer)
    end

    timer_ref = schedule_flush(state.flush_interval)
    {:noreply, %{state | buffer: [], timer_ref: timer_ref}}
  end

  # ===================== Private Functions =====================

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end

  defp do_flush(buffer) do
    start_time = System.monotonic_time()
    record_count = length(buffer)

    # Group by module for efficient batch operations
    buffer
    |> Enum.reverse()
    |> Enum.group_by(fn {module, _data, _ts} -> module end)
    |> Enum.each(fn {module, events} ->
      write_batch(module, events)
    end)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:hyperliquid, :storage, :flush, :stop],
      %{record_count: record_count, duration: duration},
      %{}
    )
  end

  defp write_batch(module, events) do
    events_data = Enum.map(events, fn {_mod, data, _ts} -> data end)

    # Flatten if any event_data is itself a list (e.g., trades come as a list)
    flattened_data = flatten_event_data(events_data)

    # Check if module has storage config
    unless function_exported?(module, :storage_enabled?, 0) and module.storage_enabled?() do
      :ok
    else
      # Write to Postgres if enabled
      if function_exported?(module, :postgres_enabled?, 0) and module.postgres_enabled?() do
        write_to_postgres(module, flattened_data)
      end

      # Write to cache if enabled - each item gets its own cache key
      if function_exported?(module, :cache_enabled?, 0) and module.cache_enabled?() do
        Enum.each(flattened_data, &write_to_cache(module, &1))
      end
    end
  rescue
    error ->
      Logger.error(
        "[Storage.Writer] Failed to write batch for #{inspect(module)}: #{Exception.message(error)}"
      )
  end

  # Flatten event data - handles when events themselves are lists (like trades)
  defp flatten_event_data(events_data) do
    Enum.flat_map(events_data, fn
      data when is_list(data) -> data
      data -> [data]
    end)
  end

  defp write_to_storage(module, event_data) do
    results = []
    Logger.info("[Storage.Writer] write_to_storage #{inspect(module)}")

    # Check if module has storage config
    unless function_exported?(module, :storage_enabled?, 0) and module.storage_enabled?() do
      {:ok, :no_storage_configured}
    else
      results =
        if function_exported?(module, :postgres_enabled?, 0) and module.postgres_enabled?() do
          [{:postgres, write_to_postgres(module, [event_data])} | results]
        else
          results
        end

      results =
        if function_exported?(module, :cache_enabled?, 0) and module.cache_enabled?() do
          [{:cache, write_to_cache(module, event_data)} | results]
        else
          results
        end

      case Enum.find(results, fn {_type, result} -> match?({:error, _}, result) end) do
        nil -> {:ok, :stored}
        {type, error} -> {:error, {type, error}}
      end
    end
  end

  defp write_to_postgres(module, events_data) when is_list(events_data) do
    # Skip if database is not enabled
    unless Hyperliquid.Config.db_enabled?() do
      Logger.debug("[Storage.Writer] Skipping Postgres write - database not enabled")
      {:ok, 0}
    else
      do_write_to_postgres(module, events_data)
    end
  end

  defp do_write_to_postgres(module, events_data) do
    Logger.info("[Storage.Writer] write_to_postgres #{inspect(module)}")

    # Get all table configs (may be multiple)
    # All endpoints (Info and Subscription) now generate __postgres_tables__/0
    table_configs = module.__postgres_tables__()

    if table_configs == [] do
      {:error, :no_table_configured}
    else
      # Write to each table
      results =
        Enum.map(table_configs, fn config ->
          write_to_single_table(module, events_data, config)
        end)

      # Aggregate results
      case Enum.find(results, fn r -> match?({:error, _}, r) end) do
        nil ->
          total_count = Enum.sum(Enum.map(results, fn {:ok, count} -> count end))

          Logger.info(
            "[Storage.Writer] Wrote #{total_count} total records across #{length(table_configs)} tables"
          )

          {:ok, total_count}

        error ->
          error
      end
    end
  end

  defp write_to_single_table(module, events_data, config) do
    table = config.table
    extract_field = config.extract
    transform_fn = config.transform

    Logger.info("[Storage.Writer] write_to_single_table #{table}")

    # Extract records for this table
    records =
      cond do
        # Extract specific field from response
        extract_field && is_atom(extract_field) ->
          Enum.flat_map(events_data, fn event ->
            case event do
              %{^extract_field => recs} when is_list(recs) -> recs
              map when is_map(map) -> Map.get(map, extract_field, []) |> List.wrap()
              _ -> []
            end
          end)

        # No extraction configured but module has extract_records/1 - use it for normalization
        function_exported?(module, :extract_records, 1) ->
          Enum.flat_map(events_data, &module.extract_records/1)

        # No extraction - use whole event
        true ->
          events_data
      end

    if records == [] do
      {:ok, 0}
    else
      # Apply custom transformation if provided
      records =
        if transform_fn && is_function(transform_fn, 1) do
          try do
            transform_fn.(records)
          rescue
            error ->
              Logger.error(
                "[Storage.Writer] Transform failed for #{table}: #{Exception.message(error)}"
              )

              reraise error, __STACKTRACE__
          end
        else
          records
        end

      # Apply field filtering if configured
      filtered_records =
        if config.fields do
          Enum.map(records, fn record ->
            Enum.reduce(config.fields, %{}, fn field, acc ->
              value = Map.get(record, field) || Map.get(record, to_string(field))
              if value, do: Map.put(acc, field, value), else: acc
            end)
          end)
        else
          # Legacy: use module's extract_postgres_fields/1 if available
          if function_exported?(module, :extract_postgres_fields, 1) do
            Enum.map(records, &module.extract_postgres_fields/1)
          else
            records
          end
        end

      # Normalize and insert
      now = DateTime.utc_now()

      entries =
        Enum.map(filtered_records, fn record ->
          record
          |> normalize_record()
          |> Map.put(:inserted_at, now)
          |> maybe_add_updated_at(config, now)
        end)

      repo = Hyperliquid.Repo

      if Code.ensure_loaded?(repo) do
        try do
          insert_opts = build_insert_opts(config)
          {count, _} = apply(repo, :insert_all, [table, entries, insert_opts])
          Logger.info("[Storage.Writer] Wrote #{count} records to #{table}")
          {:ok, count}
        rescue
          error ->
            Logger.error(
              "[Storage.Writer] Postgres insert failed for #{table}: #{Exception.message(error)}"
            )

            {:error, error}
        end
      else
        {:error, :repo_not_available}
      end
    end
  end

  # Add updated_at field if upsert is configured
  defp maybe_add_updated_at(record, config, now) do
    case config do
      %{on_conflict: {:replace, _fields}} ->
        Map.put(record, :updated_at, now)

      %{on_conflict: on_conflict} when on_conflict != :nothing ->
        Map.put(record, :updated_at, now)

      _ ->
        record
    end
  end

  # Build insert_all options based on config
  defp build_insert_opts(config) do
    case {config.conflict_target, config.on_conflict} do
      {nil, _} ->
        [on_conflict: :nothing, returning: false]

      {target, {:replace, fields}} ->
        [
          on_conflict: {:replace, fields},
          conflict_target: target,
          returning: false
        ]

      {target, on_conflict} ->
        [
          on_conflict: on_conflict,
          conflict_target: target,
          returning: false
        ]
    end
  end

  defp write_to_cache(module, event_data) do
    Logger.info("[Storage.Writer] write_to_cache #{inspect(module)}")
    cache_key = module.build_cache_key(event_data)

    unless cache_key do
      {:ok, :no_key_pattern}
    else
      ttl = module.cache_ttl()

      # Apply field filtering if configured
      filtered_data =
        if function_exported?(module, :extract_cache_fields, 1) do
          module.extract_cache_fields(event_data)
        else
          event_data
        end

      Hyperliquid.Cache.put(cache_key, filtered_data)
      Logger.info("[Storage.Writer] write_to_cache2 #{inspect(cache_key)}")

      if ttl do
        Cachex.expire(:hyperliquid, cache_key, ttl)
      end

      {:ok, cache_key}
    end
  rescue
    error ->
      Logger.error("[Storage.Writer] Cache write failed: #{Exception.message(error)}")
      {:error, error}
  end

  # Normalize a record for database insertion
  defp normalize_record(record) when is_struct(record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> normalize_record()
  end

  defp normalize_record(record) when is_map(record) do
    record
    # Transform special fields before processing
    |> transform_record()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {to_safe_atom(k), v} end)
    |> Enum.reject(fn {k, _v} -> k == :__unknown__ end)
    |> Map.new()
  end

  # Transform record fields for storage compatibility
  # Handles: trades users array, explorer block camelCase fields, clearinghouse nested state
  defp transform_record(record) do
    record
    |> transform_users()
    |> transform_explorer_block()
    |> transform_clearinghouse()
  end

  # Transform users: [buyer, seller] into buyer/seller fields (for trades)
  defp transform_users(%{"users" => [buyer, seller]} = record) do
    record
    |> Map.put("buyer", buyer)
    |> Map.put("seller", seller)
    |> Map.delete("users")
  end

  defp transform_users(%{users: [buyer, seller]} = record) do
    record
    |> Map.put(:buyer, buyer)
    |> Map.put(:seller, seller)
    |> Map.delete(:users)
  end

  defp transform_users(record), do: record

  # Transform explorer block camelCase fields to snake_case
  defp transform_explorer_block(%{"blockTime" => block_time} = record) do
    record
    |> Map.put("time", block_time)
    |> Map.delete("blockTime")
    |> transform_num_txs()
  end

  defp transform_explorer_block(record), do: record

  defp transform_num_txs(%{"numTxs" => num_txs} = record) do
    record
    |> Map.put("num_txs", num_txs)
    |> Map.delete("numTxs")
  end

  defp transform_num_txs(record), do: record

  # Transform clearinghouseState nested object to flat fields
  defp transform_clearinghouse(%{"clearinghouseState" => state} = record) when is_map(state) do
    record
    |> Map.put("margin_summary", Map.get(state, "marginSummary"))
    |> Map.put("cross_margin_summary", Map.get(state, "crossMarginSummary"))
    |> Map.put("withdrawable", Map.get(state, "withdrawable"))
    |> Map.put("asset_positions", Map.get(state, "assetPositions"))
    |> Map.delete("clearinghouseState")
  end

  defp transform_clearinghouse(record), do: record

  # Convert string key to atom safely (only for known fields)
  defp to_safe_atom(key) when is_atom(key), do: key

  defp to_safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unknown__
  end
end
