# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshXtdb.Drop do
  @shortdoc "Drops (detaches) an XTDB database"

  @moduledoc """
  Drops an XTDB database by detaching it from the XTDB instance.

  ## Usage

      mix ash_xtdb.drop [DATABASE_NAME] [options]

  If no database name is provided, uses the database from the repo config.

  ## Examples

      # Drop the database configured in your repo
      mix ash_xtdb.drop

      # Drop without confirmation
      mix ash_xtdb.drop --yes

      # Drop and wipe storage
      mix ash_xtdb.drop --wipe

      # Drop a specific database
      mix ash_xtdb.drop my_project

  ## Options

    * `--repo` - Use this repo's configuration (auto-discovered if not specified)
    * `--hostname` - Override XTDB hostname
    * `--port` - Override XTDB port
    * `--wipe` - Also delete the database storage (requires Docker)
    * `--container` - Docker container name (default: xtdb)
    * `--yes` or `-y` - Skip confirmation prompt
    * `--quiet` - Suppress output

  ## Notes

  By default, this only detaches the database. The data remains on disk and can
  be re-attached later using `mix ash_xtdb.setup`. Use `--wipe` to permanently delete
  the data.

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
          wipe: :boolean,
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
        _ -> Mix.raise("Too many arguments. Usage: mix ash_xtdb.drop [DATABASE_NAME]")
      end

    drop_database(database_name, repo, opts)
  end

  defp drop_database(database_name, repo, opts) do
    if database_name == "xtdb" do
      Mix.raise("Cannot drop the primary 'xtdb' database.")
    end

    quiet = Keyword.get(opts, :quiet, false)
    wipe = Keyword.get(opts, :wipe, false)
    skip_confirm = Keyword.get(opts, :yes, false)

    action = if wipe, do: "detach and permanently delete", else: "detach"

    unless skip_confirm do
      unless Mix.shell().yes?("This will #{action} database '#{database_name}'. Continue?") do
        Mix.raise("Aborted.")
      end
    end

    conn_opts = Helpers.connection_opts(repo, opts)
    conn_opts = Keyword.put(conn_opts, :database, "xtdb")

    unless quiet do
      Mix.shell().info("Connecting to XTDB at #{conn_opts[:hostname]}:#{conn_opts[:port]}...")
    end

    {:ok, conn} = Helpers.start_connection(conn_opts)

    unless quiet, do: Mix.shell().info("Detaching database '#{database_name}'...")

    case Helpers.execute(conn, "DETACH DATABASE #{database_name}") do
      {:ok, _} ->
        unless quiet, do: Mix.shell().info("Database '#{database_name}' detached.")

      {:error, %{postgres: %{message: message}}} ->
        if String.contains?(message, "does not exist") do
          unless quiet, do: Mix.shell().info("Database '#{database_name}' was not attached.")
        else
          Helpers.stop_connection(conn)
          Mix.raise("Failed to detach database: #{message}")
        end

      {:error, error} ->
        Helpers.stop_connection(conn)
        Mix.raise("Failed to detach database: #{inspect(error)}")
    end

    if wipe do
      unless quiet, do: Mix.shell().info("Wiping storage for '#{database_name}'...")

      container = Helpers.container(repo, opts)

      case wipe_storage(database_name, container) do
        :ok ->
          unless quiet, do: Mix.shell().info("Storage wiped successfully.")

        {:error, :docker_not_available} ->
          Mix.shell().error("Could not wipe storage: Docker container not available.")

        {:error, reason} ->
          Mix.shell().error("Failed to wipe storage: #{reason}")
      end
    else
      unless quiet do
        Mix.shell().info("")
        Mix.shell().info("Data remains on disk. To re-attach: mix ash_xtdb.setup #{database_name}")
        Mix.shell().info("To permanently delete: mix ash_xtdb.drop #{database_name} --wipe")
      end
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
