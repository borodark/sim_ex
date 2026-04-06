defmodule Sim.MixProject do
  use Mix.Project

  @version "0.1.3"
  @source_url "https://github.com/borodark/sim_ex"

  def project do
    [
      app: :sim_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Discrete-event simulation engine for the BEAM. " <>
          "14 Arena-style DSL verbs — seize, hold, release, decide, batch, split, combine, " <>
          "route, transport, assign, depart, plus preemptive resources and conveyors. " <>
          "Parallel replications by default: 30x faster than SimPy on 88 cores. " <>
          "Rust NIF engine for batch workloads. Property-tested (PropEr) and " <>
          "adversarial-tested (proper_statem). Zero runtime dependencies.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: "http://dataalienist.com"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:rustler, "~> 0.36", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:propcheck, "~> 1.4", only: :test, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Website" => "http://dataalienist.com",
        "Blog: Thirty to One (vs SimPy)" => "http://dataalienist.com/blog-simpy-race.html",
        "Blog: proper_statham" => "http://dataalienist.com/blog-statham.html"
      },
      files:
        ~w(lib native/sim_nif/src native/sim_nif/Cargo.toml native/sim_nif/Cargo.lock mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Core: [Sim, Sim.Engine, Sim.Engine.Diasca, Sim.Clock, Sim.Calendar, Sim.Topology],
        Entities: [Sim.Entity, Sim.EntityManager, Sim.Source, Sim.Resource, Sim.PHOLD],
        DSL: [Sim.DSL, Sim.DSL.Process, Sim.DSL.Resource, Sim.DSL.Conveyor],
        Analysis: [Sim.Statistics, Sim.Experiment, Sim.Warmup, Sim.TimeSeries, Sim.Validate]
      ],
      source_ref: "main"
    ]
  end
end
