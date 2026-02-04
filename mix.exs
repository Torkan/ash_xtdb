# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "An Ash DataLayer for XTDB v2 with first-class bitemporal query support"
  @source_url "https://github.com/tgk/ash_xtdb"

  def cli do
    [
      preferred_envs: [
        tidewave: :test,
        test: :test
      ]
    ]
  end

  def project do
    [
      app: :ash_xtdb,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: @description,
      package: package(),

      # Docs
      name: "AshXTDB",
      docs: docs(),
      source_url: @source_url,

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_sql, "~> 0.4"},
      {:spark, "~> 2.0"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.0"},

      # Dev/test
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: [:dev, :test]},
      {:bandit, "~> 1.0", only: [:dev, :test]},
      {:usage_rules, "~> 0.1", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ],
      test: [
        "ash_xtdb.reset",
        "test"
      ],
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4032) end)'"
    ]
  end

  defp package do
    [
      maintainers: ["Torkild G. Kjevik"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        "Data Layer": [
          AshXTDB,
          AshXTDB.DataLayer,
          AshXTDB.DataLayer.Info
        ],
        Repo: [
          AshXTDB.Repo
        ],
        "Query & Changeset": [
          AshXTDB.Query,
          AshXTDB.Changeset
        ],
        SQL: [
          AshXTDB.SQL,
          AshXTDB.SQL.Filter,
          AshXTDB.SQL.Nested
        ]
      ]
    ]
  end
end
