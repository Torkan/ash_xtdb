# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Repo do
  @moduledoc """
  Defines a repository for connecting to XTDB with connection pooling.

  This repo uses DBConnection for connection pooling, automatic reconnection,
  and health checks. It connects to XTDB via the PostgreSQL wire protocol
  using the simple query protocol (no prepared statements).

  ## Usage

      defmodule MyApp.XTDBRepo do
        use AshXTDB.Repo, otp_app: :my_app
      end

  Then configure in your config:

      config :my_app, MyApp.XTDBRepo,
        hostname: "localhost",
        port: 5432,
        database: "xtdb",
        username: "xtdb",
        pool_size: 10

  ## Options

  ### Connection options

    * `:hostname` - The XTDB server hostname (default: `"localhost"`)
    * `:port` - The XTDB pgwire port (default: `5432`)
    * `:database` - The database name (default: `"xtdb"`)
    * `:username` - The username (default: `"xtdb"`)
    * `:connect_timeout` - Connection timeout in ms (default: `15_000`)
    * `:timeout` - Query timeout in ms (default: `15_000`)

  ### Pool options

    * `:pool_size` - Number of connections in the pool (default: `10`)
    * `:queue_target` - Target queue time in ms (default: `50`)
    * `:queue_interval` - Queue check interval in ms (default: `1000`)
    * `:idle_interval` - Ping interval for idle connections in ms (default: `5000`)

  ### Reconnection options

    * `:backoff_min` - Minimum backoff interval in ms (default: `1000`)
    * `:backoff_max` - Maximum backoff interval in ms (default: `30_000`)
    * `:backoff_type` - Backoff strategy: `:stop`, `:exp`, `:rand`, `:rand_exp` (default: `:rand_exp`)
  """

  @type query_result ::
          {:ok, Postgrex.Result.t()}
          | {:error, Exception.t()}

  @callback config() :: keyword()
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  @callback query(sql :: String.t(), params :: list(), opts :: keyword()) :: query_result()
  @callback query!(sql :: String.t(), params :: list(), opts :: keyword()) :: Postgrex.Result.t()
  @callback transaction(fun :: (-> any()), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour AshXTDB.Repo

      @otp_app Keyword.fetch!(opts, :otp_app)

      def child_spec(opts) do
        config = Keyword.merge(config(), opts)
        DBConnection.child_spec(AshXTDB.Connection, config)
      end

      @impl AshXTDB.Repo
      def config do
        Application.get_env(@otp_app, __MODULE__, [])
        |> Keyword.put_new(:pool_size, 10)
        |> Keyword.put_new(:name, __MODULE__)
        |> Keyword.put_new(:idle_interval, 5000)
      end

      @impl AshXTDB.Repo
      def start_link(opts \\ []) do
        config = Keyword.merge(config(), opts)
        DBConnection.start_link(AshXTDB.Connection, config)
      end

      @impl AshXTDB.Repo
      def query(sql, params \\ [], opts \\ []) do
        query = %AshXTDB.SimpleQuery{statement: sql}
        pool = get_conn(opts)

        case DBConnection.execute(pool, query, params, opts) do
          {:ok, _query, result} -> {:ok, result}
          {:error, _} = error -> error
        end
      end

      @impl AshXTDB.Repo
      def query!(sql, params \\ [], opts \\ []) do
        case query(sql, params, opts) do
          {:ok, result} -> result
          {:error, error} -> raise error
        end
      end

      @impl AshXTDB.Repo
      def transaction(fun, opts \\ []) when is_function(fun, 0) do
        pool = get_conn(opts)

        DBConnection.transaction(
          pool,
          fn conn ->
            # Store connection in process dictionary for nested queries
            previous = Process.get(:ash_xtdb_conn)
            Process.put(:ash_xtdb_conn, conn)

            try do
              fun.()
            after
              if previous do
                Process.put(:ash_xtdb_conn, previous)
              else
                Process.delete(:ash_xtdb_conn)
              end
            end
          end,
          opts
        )
      end

      @doc """
      Runs a function with a checked out connection.

      Useful for running multiple queries on the same connection without
      starting a transaction.
      """
      def run(fun, opts \\ []) when is_function(fun, 0) do
        pool = get_conn(opts)

        DBConnection.run(
          pool,
          fn conn ->
            previous = Process.get(:ash_xtdb_conn)
            Process.put(:ash_xtdb_conn, conn)

            try do
              fun.()
            after
              if previous do
                Process.put(:ash_xtdb_conn, previous)
              else
                Process.delete(:ash_xtdb_conn)
              end
            end
          end,
          opts
        )
      end

      @doc """
      Rolls back the current transaction.

      Can only be called inside a transaction. Will cause the transaction
      function to return `{:error, reason}`.
      """
      def rollback(reason) do
        case Process.get(:ash_xtdb_conn) do
          nil ->
            raise "cannot call rollback outside of transaction"

          conn ->
            DBConnection.rollback(conn, reason)
        end
      end

      @doc """
      Checks if currently inside a transaction.
      """
      def in_transaction? do
        Process.get(:ash_xtdb_conn) != nil
      end

      # Get the connection - either from process dict (in transaction) or pool
      defp get_conn(opts) do
        case Keyword.get(opts, :conn) do
          nil ->
            case Process.get(:ash_xtdb_conn) do
              nil -> __MODULE__
              conn -> conn
            end

          conn ->
            conn
        end
      end

      defoverridable config: 0, start_link: 1, query: 3, query!: 3, transaction: 2
    end
  end
end
