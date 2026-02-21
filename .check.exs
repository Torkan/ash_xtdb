[
  tools: [
    {:compiler, "mix compile --warnings-as-errors"},
    {:formatter, "mix format --check-formatted"},
    {:credo, "mix credo --strict"},
    {:ex_unit, env: %{"MIX_ENV" => "test"}},
    {:dialyzer, "mix dialyzer"},
    {:sobelow, false}
  ]
]
