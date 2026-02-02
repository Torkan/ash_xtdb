# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshXtdb.Reset do
  @shortdoc "Resets an XTDB database (detach, wipe, re-attach)"

  @moduledoc """
  Resets an XTDB database by detaching it, wiping its storage, and re-attaching.

  ## Usage

      mix ash_xtdb.reset [DATABASE_NAME] [options]

  If no database name is provided, uses the database from the repo config.

  ## Examples

      # Reset the database configured in your repo
      mix ash_xtdb.reset

      # Reset without confirmation
      mix ash_xtdb.reset --yes

      # Reset a specific database
      mix ash_xtdb.reset my_project

  ## Options

    * `--repo` - Use this repo's configuration (auto-discovered if not specified)
    * `--hostname` - Override XTDB hostname
    * `--port` - Override XTDB port
    * `--container` - Docker container name (default: xtdb)
    * `--yes` or `-y` - Skip confirmation prompt
    * `--quiet` - Suppress output

  ## Warning

  This will permanently delete all data in the database. The operation cannot be undone.

  ## Configuration

  The task reads settings from your repo configuration:

      config :my_app, MyApp.XTDBRepo,
        hostname: "localhost",
        port: 5433,
        database: "my_project",
        container: "xtdb"
  """

  use Mix.Task

  alias Mix.Tasks.AshXtdb, as: Helpers

  @storage_path "/var/lib/xtdb"

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started()

    {opts, args, _} =
      OptionParser.parse(args,
        strict: [
          hostname: :string,
          port: :integer,
          repo: :string,
          container: :string,
          yes: :boolean,
          quiet: :boolean
        ],
        aliases: [y: :yes]
      )

    repo = Helpers.parse_repo(opts)

    database_name =
      case args do
        [name] -> name
        [] -> Helpers.database(repo) || Mix.raise("No database name provided or configured in repo")
        _ -> Mix.raise("Too many arguments. Usage: mix ash_xtdb.reset [DATABASE_NAME]")
      end

    reset_database(database_name, repo, opts)
  end

  defp reset_database(database_name, repo, opts) do
    if database_name == "xtdb" do
      Mix.raise("Cannot reset the primary 'xtdb' database.")
    end

    quiet = Keyword.get(opts, :quiet, false)
    skip_confirm = Keyword.get(opts, :yes, false)

    unless skip_confirm do
      unless Mix.shell().yes?(
               "This will permanently delete all data in '#{database_name}'. Continue?"
             ) do
        Mix.raise("Aborted.")
      end
    end

    conn_opts = Helpers.connection_opts(repo, opts)
    conn_opts = Keyword.put(conn_opts, :database, "xtdb")

    unless quiet do
      Mix.shell().info("Connecting to XTDB at #{conn_opts[:hostname]}:#{conn_opts[:port]}...")
    end

    {:ok, conn} = Helpers.start_connection(conn_opts)

    # Step 1: Detach the database
    unless quiet, do: Mix.shell().info("Detaching database '#{database_name}'...")

    case Helpers.execute(conn, "DETACH DATABASE #{database_name}") do
      {:ok, _} ->
        :ok

      {:error, %{postgres: %{message: message}}} ->
        if String.contains?(message, "does not exist") do
          unless quiet, do: Mix.shell().info("Database was not attached, skipping detach.")
        else
          Helpers.stop_connection(conn)
          Mix.raise("Failed to detach database: #{message}")
        end

      {:error, error} ->
        Helpers.stop_connection(conn)
        Mix.raise("Failed to detach database: #{inspect(error)}")
    end

    # Step 2: Wipe storage (via Docker)
    unless quiet, do: Mix.shell().info("Wiping storage for '#{database_name}'...")

    container = Helpers.container(repo, opts)

    case wipe_storage(database_name, container) do
      :ok ->
        :ok

      {:error, :docker_not_available} ->
        unless quiet do
          Mix.shell().info(
            "Warning: Could not wipe storage via Docker. You may need to manually delete the database storage."
          )
        end

      {:error, reason} ->
        unless quiet do
          Mix.shell().info("Warning: Failed to wipe storage: #{reason}")
        end
    end

    # Step 3: Re-attach the database
    unless quiet, do: Mix.shell().info("Re-attaching database '#{database_name}'...")

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
        unless quiet, do: Mix.shell().info("Database '#{database_name}' reset successfully.")

      {:error, %{postgres: %{message: message}}} ->
        Helpers.stop_connection(conn)
        Mix.raise("Failed to re-attach database: #{message}")

      {:error, error} ->
        Helpers.stop_connection(conn)
        Mix.raise("Failed to re-attach database: #{inspect(error)}")
    end

    Helpers.stop_connection(conn)
  end

  defp wipe_storage(database_name, container) do
    full_path = "#{@storage_path}/#{database_name}"

    case System.cmd("docker", ["exec", container, "rm", "-rf", full_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, 1} ->
        if String.contains?(output, "No such container") do
          {:error, :docker_not_available}
        else
          {:error, output}
        end

      {output, _} ->
        {:error, output}
    end
  rescue
    _ -> {:error, :docker_not_available}
  end
end
