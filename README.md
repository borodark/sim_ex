# sim_ex

Discrete-event simulation engine for the BEAM.

Lightweight processes as entities, ETS-based shared topology,
barrier synchronization, streaming Welford statistics. Zero dependencies.


![Atom DSL](assets/barbershop.png)


## Quick Start

```elixir
# M/M/1 queue: Poisson arrivals, exponential service
{:ok, result} = Sim.run(
  entities: [
    {:arrivals, Sim.Source, %{id: :arrivals, target: :server,
      interarrival: {:exponential, 1.0}, seed: 42}},
    {:server, Sim.Resource, %{id: :server, capacity: 1,
      service: {:exponential, 0.5}, seed: 99}}
  ],
  initial_events: [{0.0, :arrivals, :generate}],
  stop_time: 10_000.0
)

result.stats[:server]
# %{arrivals: 10042, departures: 10041, mean_wait: 0.49, ...}
```

## Architecture

```
Sim.Clock ──── advances virtual time event-by-event
    │
Sim.Calendar ─ priority queue (:gb_trees, FIFO tie-breaking)
    │
Sim.EntityManager ─ registry + dispatch
    │
    ├── Sim.Entity ─── @behaviour: init/1, handle_event/3, statistics/1
    ├── Sim.Resource ── capacity-limited server with FIFO queue
    ├── Sim.Source ──── arrival generator (exponential, constant)
    └── Sim.PHOLD ──── standard DES benchmark entity
    
Sim.Topology ──── ETS shared state (networks, occupancy, routing)
Sim.Statistics ── Welford streaming mean/variance + batch means CI
Sim.Experiment ── replications, CRN, paired comparison
```

### Design Principles

1. **Process = entity** (InterSCSimulator pattern). Inline mode for speed, process mode for scale.
2. **ETS for topology** — shared reads are free, writes are rare. No actor-per-link bottleneck.
3. **Barrier synchronization** — all entities complete current event before clock advances. Simple, correct.
4. **Functional PRNG** — `:rand` state threaded through entities. Same seed = same trajectory. CRN for free.
5. **Zero dependencies** — pure Elixir + OTP. Optional integration with Les Trois Chambrées.

## DSL for Subject Matter Experts

GPSS/Arena-inspired syntax that compiles to Entity modules:

```elixir
defmodule Barbershop do
  use Sim.DSL

  model :barbershop do
    resource :barber, capacity: 1

    process :customer do
      arrive every: exponential(18.0)
      seize :barber
      hold exponential(16.0)
      release :barber
      depart
    end
  end
end

Barbershop.run(stop_time: 10_000.0, seed: 42)
```

No magic runtime. `mix compile` generates standard `Sim.Entity` modules.
Works in both engine and tick-diasca modes.

## Tick-Diasca Engine

Causal ordering via two-level timestamps (Sim-Diasca pattern). Entity at
`(T, D)` produces events stamped `(T, D+1)`. Tick advances only when no
more diascas are pending (quiescence).

```elixir
# Entities return tagged events:
{:same_tick, target, payload}    # → (T, D+1)
{:tick, future_tick, target, payload}  # → (future_tick, 0)
{:delay, delta, target, payload}       # → (T + delta, 0)
```

```elixir
Sim.run(
  mode: :diasca,
  entities: [...],
  initial_events: [{0, :source, :generate}],
  stop_tick: 10_000
)
```

## PHOLD Benchmark

The standard synthetic benchmark for DES engines. Each logical process
receives an event, does minimal work, sends a new event to a random LP.

```bash
mix run benchmark/phold_bench.exs
```

## Writing Entities

Implement the `Sim.Entity` behaviour:

```elixir
defmodule MyMachine do
  @behaviour Sim.Entity

  @impl true
  def init(config) do
    {:ok, %{id: config.id, processed: 0}}
  end

  @impl true
  def handle_event({:job, job_id}, clock, state) do
    # Process the job, schedule completion
    finish_time = clock + 5.0
    events = [{finish_time, :sink, {:done, job_id}}]
    {:ok, %{state | processed: state.processed + 1}, events}
  end

  @impl true
  def statistics(state), do: %{processed: state.processed}
end
```

## Experimental Design

```elixir
# 30 independent replications, parallel across cores
results = Sim.Experiment.replicate(fn seed ->
  {:ok, r} = Sim.run(my_model(seed))
  r.stats[:server]
end, 30, parallel: true)

# Compare two configurations with common random numbers
comparison = Sim.Experiment.compare(
  config_a: fn seed -> run_model(config_a, seed) end,
  config_b: fn seed -> run_model(config_b, seed) end,
  seeds: 1..30,
  metric: :mean_wait
)
# => %{mean_diff: -0.12, ci: {-0.18, -0.06}, significant: true}
```

## Three Comrades

sim_ex is part of an Elixir probabilistic computing ecosystem:

| Library | What | Role in Simulation |
|---------|------|-------------------|
| **sim_ex** | DES engine | The simulator itself |
| [eXMC](https://github.com/borodark/eXMC) | NUTS/HMC, ADVI, Pathfinder | Input modeling: posterior over distribution params |
| [smc_ex](https://github.com/borodark/smc_ex) | O-SMC², particle filters | Self-calibrating digital twins |
| [StochTree-Ex](https://github.com/borodark/stochtree_ex) | BART | Metamodeling: which inputs drive output |

```elixir
# Optional deps — sim_ex works standalone
def deps do
  [
    {:sim_ex, "~> 0.1"},
    {:exmc, "~> 0.2", optional: true},        # Bayesian input modeling
    {:smc_ex, "~> 0.1", optional: true},       # Online calibration
    {:stochtree_ex, "~> 0.1", optional: true}  # Sensitivity analysis
  ]
end
```

## Installation

```elixir
def deps do
  [
    {:sim_ex, "~> 0.1.0"}
  ]
end
```

## License

Apache-2.0
