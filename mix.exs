defmodule Sim.MixProject do
  use Mix.Project

  @version "0.1.0"
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
          "Lightweight processes as entities, ETS topology, barrier synchronization. " <>
          "Zero dependencies.",
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Website" => "http://dataalienist.com"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
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
        DSL: [Sim.DSL, Sim.DSL.Process, Sim.DSL.Resource],
        Analysis: [Sim.Statistics, Sim.Experiment]
      ],
      source_ref: "v#{@version}"
    ]
  end
end
