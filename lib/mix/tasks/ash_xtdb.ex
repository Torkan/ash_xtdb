# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshXtdb do
  @moduledoc """
  Shared utilities for AshXTDB mix tasks.
  """

  @doc """
  Ensures the application is configured and db_connection is started.
  Call this at the start of each mix task.
  """
  def ensure_started do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:db_connection)
    :ok
  end

  @doc """
  Finds all AshXTDB repos configured in the application.

  Looks for repos configured under `:ash_xtdb` application config:

      config :ash_xtdb, repos: [MyApp.XTDBRepo]

  Or discovers repos that use `AshXTDB.Repo`.
  """
  def repos do
    Application.get_env(:ash_xtdb, :repos, [])
    |> case do
      [] -> discover_repos()
      repos -> repos
    end
  end

  @doc """
  Gets a single repo, raising if none or multiple are found.
  """
  def repo! do
    case repos() do
      [repo] ->
        repo

      [] ->
        Mix.raise("""
        No AshXTDB repo found. Either:
        1. Configure repos in config: `config :ash_xtdb, repos: [MyApp.XTDBRepo]`
        2. Pass --repo explicitly: `mix ash_xtdb.setup my_db --repo MyApp.XTDBRepo`
        """)

      repos ->
        Mix.raise("""
        Multiple repos found: #{inspect(repos)}
        Please specify which repo to use with --repo
        """)
    end
  end

  @doc """
  Parses a repo option, falling back to auto-discovery.
  """
  def parse_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        repo!()

      repo_name ->
        repo = Module.concat([repo_name])

        if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
          repo
        else
          Mix.raise("Repo #{repo_name} not found or doesn't implement config/0")
        end
    end
  end

  @doc """
  Gets connection options from a repo's config.
  """
  def connection_opts(repo, overrides \\ []) do
    config = repo.config()

    config
    |> Keyword.put_new(:hostname, "localhost")
    |> Keyword.put_new(:port, 5432)
    |> Keyword.put_new(:username, "xtdb")
    |> Keyword.merge(Keyword.take(overrides, [:hostname, :port]))
  end

  @doc """
  Gets the container name from repo config or application config.
  """
  def container(repo, overrides \\ []) do
    Keyword.get(overrides, :container) ||
      Keyword.get(repo.config(), :container) ||
      Application.get_env(:ash_xtdb, :container) ||
      "xtdb"
  end

  @doc """
  Gets the database name from repo config.
  """
  def database(repo) do
    Keyword.get(repo.config(), :database)
  end

  @doc """
  Starts a single connection (not pooled) for mix tasks.
  """
  def start_connection(opts) do
    DBConnection.start_link(AshXTDB.Connection, Keyword.put(opts, :pool_size, 1))
  end

  @doc """
  Executes a SQL query on a connection.
  """
  def execute(conn, sql) do
    query = %AshXTDB.SimpleQuery{statement: sql}

    case DBConnection.execute(conn, query, []) do
      {:ok, _query, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  @doc """
  Stops a connection.
  """
  def stop_connection(conn) do
    GenServer.stop(conn)
  end

  # Discovers repos by scanning application modules
  defp discover_repos do
    # Get all applications that depend on ash_xtdb
    apps =
      Application.loaded_applications()
      |> Enum.map(fn {app, _, _} -> app end)
      |> Enum.filter(fn app ->
        case Application.spec(app, :applications) do
          nil -> false
          deps -> :ash_xtdb in deps
        end
      end)

    # For each app, check if there's a configured repo
    Enum.flat_map(apps, fn app ->
      Application.get_all_env(app)
      |> Enum.filter(fn {key, value} ->
        is_atom(key) and is_list(value) and Keyword.has_key?(value, :hostname)
      end)
      |> Enum.map(fn {module, _config} -> module end)
      |> Enum.filter(fn module ->
        Code.ensure_loaded?(module) and
          function_exported?(module, :__info__, 1) and
          ash_xtdb_repo?(module)
      end)
    end)
  end

  # Checks if a module is an AshXTDB.Repo by looking at its behaviours
  defp ash_xtdb_repo?(module) do
    behaviours = module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    AshXTDB.Repo in behaviours
  rescue
    _ -> false
  end
end
