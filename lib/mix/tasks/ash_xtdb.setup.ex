# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshXtdb.Setup do
  @shortdoc "Sets up (attaches) an XTDB database"

  @moduledoc """
  Sets up a new XTDB database by attaching it to the XTDB instance.

  ## Usage

      mix ash_xtdb.setup [DATABASE_NAME] [options]

  If no database name is provided, uses the database from the repo config.

  ## Examples

      # Attach the database configured in your repo
      mix ash_xtdb.setup

      # Attach a specific database
      mix ash_xtdb.setup my_project

      # Use a specific repo
      mix ash_xtdb.setup --repo MyApp.XTDBRepo

  ## Options

    * `--repo` - Use this repo's configuration (auto-discovered if not specified)
    * `--hostname` - Override XTDB hostname
    * `--port` - Override XTDB port
    * `--quiet` - Suppress output

  ## Configuration

  The task reads connection settings from your repo configuration:

      config :my_app, MyApp.XTDBRepo,
        hostname: "localhost",
        port: 5433,
        database: "my_project"

  Or configure repos globally:

      config :ash_xtdb, repos: [MyApp.XTDBRepo]
  """

  use Mix.Task

  alias Mix.Tasks.AshXtdb, as: Helpers

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started()

    {opts, args, _} =
      OptionParser.parse(args,
        strict: [
          hostname: :string,
          port: :integer,
          repo: :string,
          quiet: :boolean
        ]
      )

    repo = Helpers.parse_repo(opts)

    database_name =
      case args do
        [name] ->
          name

        [] ->
          Helpers.database(repo) || Mix.raise("No database name provided or configured in repo")

        _ ->
          Mix.raise("Too many arguments. Usage: mix ash_xtdb.setup [DATABASE_NAME]")
      end

    setup_database(database_name, repo, opts)
  end

  defp setup_database(database_name, repo, opts) do
    quiet = Keyword.get(opts, :quiet, false)
    conn_opts = Helpers.connection_opts(repo, opts)

    # Always connect to 'xtdb' to run ATTACH
    conn_opts = Keyword.put(conn_opts, :database, "xtdb")

    unless quiet do
      Mix.shell().info("Connecting to XTDB at #{conn_opts[:hostname]}:#{conn_opts[:port]}...")
    end

    {:ok, conn} = Helpers.start_connection(conn_opts)

    attach_sql = """
    ATTACH DATABASE #{database_name} WITH $$
      log: !Local
        path: '/var/lib/xtdb/#{database_name}/log'
      storage: !Local
        path: '/var/lib/xtdb/#{database_name}/storage'
    $$
    """

    case Helpers.execute(conn, attach_sql) do
      {:ok, _} ->
        unless quiet do
          Mix.shell().info("Database '#{database_name}' attached successfully.")
        end

      {:error, %{postgres: %{message: message}}} ->
        if String.contains?(message, "already exists") do
          unless quiet do
            Mix.shell().info("Database '#{database_name}' already exists.")
          end
        else
          Mix.raise("Failed to attach database: #{message}")
        end

      {:error, error} ->
        Mix.raise("Failed to attach database: #{inspect(error)}")
    end

    Helpers.stop_connection(conn)
  end
end
