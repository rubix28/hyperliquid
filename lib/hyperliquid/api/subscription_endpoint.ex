defmodule Hyperliquid.Api.SubscriptionEndpoint do
  @moduledoc """
  DSL for defining WebSocket subscription endpoints.

  This macro reduces boilerplate while preserving explicit Ecto schemas for
  event validation and optional storage configuration.

  ## Usage

      defmodule Hyperliquid.Api.Subscription.L2Book do
        use Hyperliquid.Api.SubscriptionEndpoint,
          request_type: "l2Book",
          params: [:coin],
          optional_params: [:nSigFigs, :mantissa],
          storage: [
            cache: [enabled: true, key_pattern: "l2book:{{coin}}"]
          ]

        @primary_key false
        embedded_schema do
          field :coin, :string
          field :levels, {:array, {:array, :any}}
          field :time, :integer
        end

        def changeset(event \\ %__MODULE__{}, attrs) do
          event
          |> cast(attrs, [:coin, :levels, :time])
        end
      end

  ## Generated Functions

  - `build_request/1` - Build and validate subscription request
  - `__subscription_info__/0` - Returns metadata for the manager
  - `__storage_config__/0` - Returns storage configuration
  - `generate_subscription_key/1` - Generate unique key for this subscription variant
  - `build_cache_key/1` - Generate cache key from event data (if cache enabled)
  - `extract_records/1` - Extract records from event for storage (if postgres enabled)

  ## Options

  - `:request_type` - Required. The subscription type (e.g., "l2Book")
  - `:params` - List of required parameters as atoms
  - `:optional_params` - List of optional parameters as atoms
  - `:connection_type` - Connection routing strategy:
    - `:shared` - Can share connection with other subscriptions (default)
    - `:dedicated` - Needs its own connection per parameter variant
    - `:user_grouped` - Must share connection with other subs for same user
  - `:doc` - Short description of the subscription
  - `:key_fields` - Fields to include in subscription key (default: all params)
  - `:ws_url` - Custom WebSocket URL function (e.g., `&Hyperliquid.Config.rpc_ws_url/0`)
  - `:storage` - Storage configuration (see below)

  ## Storage Options

  The `:storage` option accepts a keyword list with the following backends:

  ### Postgres Storage

      storage: [
        postgres: [
          enabled: true,
          table: "trades",
          extract: :trades,  # optional: field containing nested records to store
          fields: [:coin, :side, :px]  # optional: only store these fields
        ]
      ]

  ### Cache Storage

      storage: [
        cache: [
          enabled: true,
          ttl: :timer.minutes(5),       # optional TTL
          key_pattern: "l2book:{{coin}}", # template with {{field}} placeholders
          fields: [:coin, :levels]      # optional: only cache these fields
        ]
      ]

  Both backends can be enabled simultaneously.

  ### Partial Storage (fields option)

  Use the `fields` option to save only specific fields from complex events.
  This is useful for subscriptions like `webData2` that contain both user-specific
  data and market data, where you only want to persist certain parts:

      storage: [
        postgres: [
          enabled: true,
          table: "user_snapshots",
          fields: [:user, :clearinghouse_state, :open_orders, :spot_state]
        ]
      ]

  """

  defmacro __using__(opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @subscription_opts unquote(opts)

      @before_compile Hyperliquid.Api.SubscriptionEndpoint
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :subscription_opts)

    request_type = Keyword.fetch!(opts, :request_type)
    params = Keyword.get(opts, :params, [])
    optional_params = Keyword.get(opts, :optional_params, [])
    connection_type = Keyword.get(opts, :connection_type, :shared)
    doc = Keyword.get(opts, :doc, "")
    key_fields = Keyword.get(opts, :key_fields, params ++ optional_params)
    ws_url_raw = Keyword.get(opts, :ws_url, nil)
    storage = Keyword.get(opts, :storage, [])
    # Escape the ws_url so it's properly stored as a function reference
    ws_url_ast = if ws_url_raw, do: Macro.escape(ws_url_raw), else: nil

    all_params = params ++ optional_params

    # Extract storage config
    postgres_config = Keyword.get(storage, :postgres, [])
    cache_config = Keyword.get(storage, :cache, [])

    # Parse multi-table configuration (same format as endpoint.ex)
    postgres_tables = parse_postgres_tables(postgres_config)
    postgres_enabled = postgres_tables != []

    # Legacy single-table fields (for backwards compatibility)
    primary_table = get_primary_table(postgres_tables)
    primary_extract = get_primary_extract(postgres_tables)
    postgres_fields = Keyword.get(postgres_config, :fields)

    cache_enabled = Keyword.get(cache_config, :enabled, false)
    cache_ttl = Keyword.get(cache_config, :ttl)
    cache_key_pattern = Keyword.get(cache_config, :key_pattern)
    cache_fields = Keyword.get(cache_config, :fields)

    # Generate storage config function
    storage_ast =
      quote do
        @doc """
        Returns postgres table configurations (multi-table support).
        """
        def __postgres_tables__, do: unquote(Macro.escape(postgres_tables))

        @doc """
        Returns storage configuration for this subscription.
        """
        def __storage_config__ do
          %{
            postgres: %{
              enabled: unquote(postgres_enabled),
              tables: __postgres_tables__(),
              # Legacy single-table fields (primary table)
              table: unquote(primary_table),
              extract: unquote(primary_extract),
              fields: unquote(postgres_fields)
            },
            cache: %{
              enabled: unquote(cache_enabled),
              ttl: unquote(cache_ttl),
              key_pattern: unquote(cache_key_pattern),
              fields: unquote(cache_fields)
            }
          }
        end

        @doc """
        Returns true if any storage backend is enabled.
        """
        def storage_enabled? do
          unquote(postgres_enabled) or unquote(cache_enabled)
        end

        @doc """
        Returns true if postgres storage is enabled.
        """
        def postgres_enabled?, do: unquote(postgres_enabled)

        @doc """
        Returns true if cache storage is enabled.
        """
        def cache_enabled?, do: unquote(cache_enabled)

        @doc """
        Build a cache key from event data using the configured pattern.

        Returns `nil` if cache is not enabled or no pattern is configured.
        """
        def build_cache_key(event_data) do
          pattern = unquote(cache_key_pattern)

          if unquote(cache_enabled) and pattern do
            Hyperliquid.Api.SubscriptionEndpoint.interpolate_key_pattern(pattern, event_data)
          else
            nil
          end
        end

        @doc false
        def extract_records(event) do
          extract_field = unquote(primary_extract)

          if extract_field do
            case event do
              %{^extract_field => records} when is_list(records) ->
                # Extract context fields (everything except the extracted field)
                context = Map.delete(event, extract_field)

                # Merge context into each record
                Enum.map(records, fn record ->
                  Map.merge(context, record)
                end)

              map when is_map(map) ->
                records = Map.get(map, extract_field, []) |> List.wrap()
                context = Map.delete(map, extract_field)

                Enum.map(records, fn record ->
                  Map.merge(context, record)
                end)

              _ ->
                []
            end
          else
            [event]
          end
        end

        @doc """
        Returns the postgres table name if configured (primary table for legacy support).
        """
        def postgres_table, do: unquote(primary_table)

        @doc """
        Returns the cache TTL if configured.
        """
        def cache_ttl, do: unquote(cache_ttl)

        @doc """
        Returns the configured postgres fields for partial storage, or nil for all fields.
        """
        def postgres_fields, do: unquote(postgres_fields)

        @doc """
        Returns the configured cache fields for partial storage, or nil for all fields.
        """
        def cache_fields, do: unquote(cache_fields)

        @doc false
        def extract_postgres_fields(event) do
          fields = unquote(postgres_fields)
          Hyperliquid.Api.SubscriptionEndpoint.extract_fields(event, fields)
        end

        @doc false
        def extract_cache_fields(event) do
          fields = unquote(cache_fields)
          Hyperliquid.Api.SubscriptionEndpoint.extract_fields(event, fields)
        end
      end

    # Generate subscription info function
    info_ast =
      quote do
        @doc """
        Returns metadata about this subscription endpoint.
        """
        def __subscription_info__ do
          %{
            request_type: unquote(request_type),
            params: unquote(params),
            optional_params: unquote(optional_params),
            connection_type: unquote(connection_type),
            doc: unquote(doc),
            key_fields: unquote(key_fields),
            ws_url: unquote(ws_url_ast),
            module: __MODULE__
          }
        end

        @doc """
        Generate a unique subscription key for this parameter set.

        ## Parameters

        - `params` - Map of subscription parameters

        ## Returns

        String key that uniquely identifies this subscription variant.
        """
        @spec generate_subscription_key(map()) :: String.t()
        unquote(
          case connection_type do
            :shared ->
              quote do
                def generate_subscription_key(_params), do: "shared"
              end

            :user_grouped ->
              quote do
                def generate_subscription_key(params) do
                  user = params[:user] || params["user"] || "unknown"
                  "user:#{user}"
                end
              end

            :dedicated ->
              quote do
                def generate_subscription_key(params) do
                  key_fields = unquote(key_fields)
                  request_type = unquote(request_type)

                  if Enum.empty?(key_fields) do
                    request_type
                  else
                    parts =
                      Enum.map(key_fields, fn field ->
                        value = params[field] || params[to_string(field)] || "nil"
                        to_string(value)
                      end)

                    "#{request_type}:#{Enum.join(parts, ":")}"
                  end
                end
              end
          end
        )
      end

    request_ast =
      if Enum.empty?(all_params) do
        # No params - simple static request
        quote do
          @type request_params :: %{}

          @doc """
          Build a subscription request.

          ## Returns

          - `{:ok, request_map}` - Subscription request
          """
          @spec build_request(map()) :: {:ok, map()}
          def build_request(_params \\ %{}) do
            {:ok, %{type: unquote(request_type)}}
          end
        end
      else
        # Build type definition for params
        param_types = build_param_types(params, optional_params)

        quote do
          @type request_params :: unquote(param_types)

          @doc """
          Build and validate a subscription request.

          ## Parameters

          - `params` - Map with keys: #{unquote(inspect(all_params))}

          ## Returns

          - `{:ok, request_map}` - Valid subscription request
          - `{:error, changeset}` - Validation errors
          """
          @spec build_request(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
          def build_request(params) when is_map(params) do
            types = unquote(build_types_map(all_params))

            changeset =
              {%{}, types}
              |> cast(params, Map.keys(types))
              |> validate_required(unquote(params))

            if changeset.valid? do
              request =
                build_request_from_changeset(
                  changeset,
                  unquote(request_type),
                  unquote(all_params)
                )

              {:ok, request}
            else
              {:error, changeset}
            end
          end

          defp build_request_from_changeset(changeset, request_type, all_params) do
            Enum.reduce(all_params, %{type: request_type}, fn param, acc ->
              case get_change(changeset, param) do
                nil -> acc
                value -> Map.put(acc, param, value)
              end
            end)
          end
        end
      end

    # Combine all ASTs
    quote do
      unquote(storage_ast)
      unquote(info_ast)
      unquote(request_ast)
    end
  end

  defp build_param_types(required, optional) do
    required_types =
      Enum.map(required, fn param ->
        {param, quote(do: term())}
      end)

    optional_types =
      Enum.map(optional, fn param ->
        {param, quote(do: term())}
      end)

    # This creates a map type spec
    quote do
      %{
        unquote_splicing(
          Enum.map(required_types, fn {k, v} ->
            quote do: {required(unquote(k)), unquote(v)}
          end) ++
            Enum.map(optional_types, fn {k, v} ->
              quote do: {optional(unquote(k)), unquote(v)}
            end)
        )
      }
    end
  end

  defp build_types_map(params) do
    # Use :any type to accept all param types (strings, integers, etc.)
    # The actual API validation happens server-side
    pairs =
      Enum.map(params, fn param ->
        {param, :any}
      end)

    {:%{}, [], pairs}
  end

  @doc """
  Interpolate a key pattern with event data.

  Replaces `{{field}}` placeholders with actual values from the event.

  ## Examples

      iex> interpolate_key_pattern("trades:{{coin}}:{{time}}", %{coin: "BTC", time: 123})
      "trades:BTC:123"

      iex> interpolate_key_pattern("l2book:{{coin}}", %{"coin" => "ETH"})
      "l2book:ETH"
  """
  @spec interpolate_key_pattern(String.t(), map()) :: String.t()
  def interpolate_key_pattern(pattern, event_data) when is_binary(pattern) do
    Regex.replace(~r/\{\{(\w+)\}\}/, pattern, fn _, field ->
      # Try string key first (WS data uses string keys), then atom key
      value =
        Map.get(event_data, field) ||
          get_atom_key(event_data, field) ||
          "unknown"

      to_string(value)
    end)
  end

  defp get_atom_key(map, field) do
    field_atom = String.to_existing_atom(field)
    Map.get(map, field_atom)
  rescue
    ArgumentError -> nil
  end

  @doc """
  Extract specific fields from an event map.

  If fields is nil or empty, returns the full event.
  Supports both atom and string keys, and handles nested structs/embeds.

  ## Examples

      iex> extract_fields(%{a: 1, b: 2, c: 3}, [:a, :b])
      %{a: 1, b: 2}

      iex> extract_fields(%{user: "0x123", data: %{x: 1}}, nil)
      %{user: "0x123", data: %{x: 1}}
  """
  @spec extract_fields(map() | struct(), list(atom()) | nil) :: map()
  def extract_fields(event, nil), do: normalize_for_storage(event)
  def extract_fields(event, []), do: normalize_for_storage(event)

  def extract_fields(event, fields) when is_list(fields) do
    fields
    |> Enum.reduce(%{}, fn field, acc ->
      value = get_field_value(event, field)

      if value != nil do
        Map.put(acc, field, normalize_for_storage(value))
      else
        acc
      end
    end)
  end

  # Get a field value from a map or struct, handling atom, string, and camelCase keys
  defp get_field_value(event, field) when is_struct(event) do
    Map.get(event, field)
  end

  defp get_field_value(event, field) when is_map(event) do
    snake_string = to_string(field)
    camel_string = to_camel_case(snake_string)

    # Try: atom key, snake_case string, camelCase string
    Map.get(event, field) ||
      Map.get(event, snake_string) ||
      Map.get(event, camel_string)
  end

  # Convert snake_case to camelCase
  defp to_camel_case(string) do
    [first | rest] = String.split(string, "_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  # Normalize values for storage (convert structs to maps, etc.)
  defp normalize_for_storage(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> normalize_for_storage()
  end

  defp normalize_for_storage(value) when is_list(value) do
    Enum.map(value, &normalize_for_storage/1)
  end

  defp normalize_for_storage(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, normalize_for_storage(v)} end)
    |> Map.new()
  end

  defp normalize_for_storage(value), do: value

  # ===================== Multi-Table Storage Parsing =====================

  @doc false
  defp parse_postgres_tables(postgres_config) when is_list(postgres_config) do
    cond do
      # New format: explicit tables array
      tables = postgres_config[:tables] ->
        Enum.map(tables, &normalize_table_config/1)

      # New format: primary + additional tables
      postgres_config[:additional_tables] ->
        primary = build_primary_table_config(postgres_config)
        additional = Enum.map(postgres_config[:additional_tables], &normalize_table_config/1)
        [primary | additional]

      # Legacy format: single table (backwards compatible)
      postgres_config[:enabled] && postgres_config[:table] ->
        [normalize_table_config(postgres_config)]

      # No postgres config or not enabled
      true ->
        []
    end
  end

  defp parse_postgres_tables(_), do: []

  @doc false
  defp normalize_table_config(config) when is_map(config) do
    %{
      table: config[:table] || config["table"],
      extract: config[:extract] || config["extract"],
      conflict_target: config[:conflict_target] || config["conflict_target"],
      on_conflict: config[:on_conflict] || config["on_conflict"] || :nothing,
      transform: config[:transform] || config["transform"],
      fields: config[:fields] || config["fields"]
    }
  end

  defp normalize_table_config(config) when is_list(config) do
    normalize_table_config(Map.new(config))
  end

  @doc false
  defp build_primary_table_config(postgres_config) do
    %{
      table: postgres_config[:table],
      extract: postgres_config[:extract],
      conflict_target: postgres_config[:conflict_target],
      on_conflict: postgres_config[:on_conflict] || :nothing,
      transform: postgres_config[:transform],
      fields: postgres_config[:fields]
    }
  end

  # Legacy helper functions for backwards compatibility
  @doc false
  defp get_primary_table([%{table: table} | _]), do: table
  defp get_primary_table(_), do: nil

  @doc false
  defp get_primary_extract([%{extract: extract} | _]), do: extract
  defp get_primary_extract(_), do: nil
end
