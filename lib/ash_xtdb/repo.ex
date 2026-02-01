# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Repo do
  @moduledoc """
  Defines a repository for connecting to XTDB.

  This repo uses a custom pgwire client that works with XTDB's limited
  PostgreSQL wire protocol support. XTDB doesn't support the pg_catalog
  queries that Postgrex requires for type discovery.

  ## Usage

      defmodule MyApp.XTDBRepo do
        use AshXTDB.Repo, otp_app: :my_app
      end

  Then configure in your config:

      config :my_app, MyApp.XTDBRepo,
        hostname: "localhost",
        port: 5432,
        database: "xtdb"

  ## Options

  - `:otp_app` - The OTP application to read config from
  """

  @type query_result ::
          {:ok, Postgrex.Result.t()}
          | {:error, Exception.t()}

  @callback config() :: keyword()
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  @callback query(sql :: String.t(), params :: list(), opts :: keyword()) :: query_result()
  @callback query!(sql :: String.t(), params :: list(), opts :: keyword()) :: Postgrex.Result.t()

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour AshXTDB.Repo

      @otp_app Keyword.fetch!(opts, :otp_app)

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }
      end

      @impl AshXTDB.Repo
      def config do
        Application.get_env(@otp_app, __MODULE__, [])
      end

      @impl AshXTDB.Repo
      def start_link(opts \\ []) do
        config = Keyword.merge(config(), opts)
        config = Keyword.put(config, :name, __MODULE__)
        AshXTDB.PgWire.start_link(config)
      end

      @impl AshXTDB.Repo
      def query(sql, params \\ [], _opts \\ []) do
        # Inline parameters since we use simple query protocol
        sql = AshXTDB.Query.inline_params(sql, params)
        AshXTDB.PgWire.query(__MODULE__, sql)
      end

      @impl AshXTDB.Repo
      def query!(sql, params \\ [], opts \\ []) do
        case query(sql, params, opts) do
          {:ok, result} -> result
          {:error, error} -> raise error
        end
      end

      defoverridable config: 0, start_link: 1, query: 3, query!: 3
    end
  end
end
