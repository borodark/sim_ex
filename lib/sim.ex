defmodule Sim do
  @moduledoc """
  Discrete-event simulation engine for the BEAM.

  Lightweight processes as entities, ETS-based topology,
  barrier synchronization, streaming statistics. Zero dependencies.

  ## Quick Start

      # M/M/1 queue: Poisson arrivals, exponential service
      {:ok, results} = Sim.run(
        entities: [
          {:arrivals, Sim.Source, %{id: :arrivals, target: :server,
            interarrival: {:exponential, 1.0}, seed: 42}},
          {:server, Sim.Resource, %{id: :server, capacity: 1,
            service: {:exponential, 0.5}, seed: 99}}
        ],
        initial_events: [{0.0, :arrivals, :generate}],
        stop_time: 10_000.0
      )

  ## Execution Modes

  - **Engine mode** (default): tight loop, single process, no message passing.
    Maximum throughput for single-node simulation. Uses `Sim.Engine`.
  - **GenServer mode** (`mode: :genserver`): each infrastructure component
    is a process. Supports interactive stepping, distributed simulation,
    streaming statistics, and fault-tolerant entity management.

  ## Architecture

  - `Sim.Engine` — tight-loop runner (default, fastest)
  - `Sim.Clock` — virtual time GenServer (interactive/distributed mode)
  - `Sim.Calendar` — priority queue GenServer
  - `Sim.Entity` — behaviour for simulation entities
  - `Sim.EntityManager` — registry + dispatch
  - `Sim.Resource` — capacity-limited server with queue
  - `Sim.Source` — arrival generator
  - `Sim.Topology` — ETS shared state for network/spatial data
  - `Sim.Statistics` — Welford streaming stats + batch means CI
  - `Sim.Experiment` — replications, CRN, paired comparison
  - `Sim.PHOLD` — standard DES benchmark

  ## Integration with Les Trois Chambrées

  - **eXMC**: fit input distribution posteriors, propagate uncertainty
  - **smc_ex**: self-calibrating digital twin via O-SMC²
  - **StochTree-Ex**: BART metamodel for sensitivity analysis
  """

  @doc """
  Run a simulation to completion.

  ## Options

  - `:entities` — list of `{id, module, config}` tuples
  - `:initial_events` — list of `{time, target, event}` to seed the calendar
  - `:stop_time` — virtual time to stop (default: `:infinity`)
  - `:mode` — `:engine` (default, fast), `:diasca` (tick-diasca causality), or `:genserver` (interactive/distributed)
  - `:stop_tick` — integer tick to stop at (diasca mode only)
  - `:topology` — list of `{key, value}` for shared state (GenServer mode only)
  - `:collect_stats` — run statistics collector (GenServer mode only)

  Returns `{:ok, %{clock: final_time, events: count, stats: entity_stats}}`.
  """
  def run(opts) do
    case Keyword.get(opts, :mode, :engine) do
      :engine -> Sim.Engine.run(opts)
      :diasca -> Sim.Engine.Diasca.run(opts)
      :genserver -> run_genserver(opts)
    end
  end

  @doc """
  Run a simulation and return a specific metric from a specific entity.
  """
  def run_metric(opts, entity_id, metric_key) do
    {:ok, result} = run(opts)
    get_in(result, [:stats, entity_id, metric_key])
  end

  # --- GenServer mode (interactive / distributed) ---

  defp run_genserver(opts) do
    entities = Keyword.fetch!(opts, :entities)
    initial_events = Keyword.fetch!(opts, :initial_events)
    stop_time = Keyword.get(opts, :stop_time, :infinity)

    {:ok, calendar} = Sim.Calendar.start_link(name: nil)
    {:ok, entity_mgr} = Sim.EntityManager.start_link(name: nil)

    stats_pid =
      if opts[:collect_stats] do
        {:ok, pid} = Sim.Statistics.start_link(name: nil, batch_size: opts[:batch_size])
        pid
      else
        nil
      end

    topo_pid =
      if opts[:topology] do
        {:ok, pid} = Sim.Topology.start_link(name: nil)
        Sim.Topology.put_many(pid, opts[:topology])
        pid
      else
        nil
      end

    Enum.each(entities, fn {id, module, config} ->
      :ok = Sim.EntityManager.register(entity_mgr, id, module, config)
    end)

    Enum.each(initial_events, fn {time, target, event} ->
      Sim.Calendar.push(calendar, time, target, event)
    end)

    {:ok, clock} =
      Sim.Clock.start_link(
        name: nil,
        calendar: calendar,
        entities: entity_mgr,
        topology: topo_pid,
        stats: stats_pid,
        stop_time: stop_time
      )

    {:ok, final_time, events_processed} = Sim.Clock.run(clock)
    entity_stats = Sim.EntityManager.all_statistics(entity_mgr)

    for pid <- [clock, calendar, entity_mgr, stats_pid, topo_pid], pid != nil do
      GenServer.stop(pid)
    end

    {:ok,
     %{
       clock: final_time,
       events: events_processed,
       stats: entity_stats
     }}
  end
end
