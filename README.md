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

Engine vs GenServer — PHOLD A/B Test
============================================================
Cores: 88

LPs     Stop  Events      Engine(ms)  GS(ms)      Eng E/s       GS E/s        Speedup
--------------------------------------------------------------------------------
100     10.0  17565       61          485         287950        36216         8.0x
1000    10.0  175940      1404        3746        125313        46967         2.7x
10000   10.0  1758030     18293       41818       96103         42040         2.3x
100     100.0 161723      633         2147        255486        75325         3.4x
1000    100.0 1614913     12375       19340       130498        83501         1.6x
10000   100.0 16156886    93348       381351      173082        42367         4.1x

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

## The Simulation That Learns

Every DES engine does Monte Carlo: run 1,000 times, sample inputs from
a fitted distribution, compute output confidence intervals. The input
parameters are treated as known constants. They are not.

sim_ex is the only DES engine where simulation inputs have proper Bayesian
posteriors, where the model self-calibrates from streaming data, and where
input structure is discovered nonparametrically.

| What others do | What sim_ex + ecosystem does |
|---|---|
| Service time = Exponential(16) | Service time = Exponential(16.2 +/- 1.3) — full posterior from 200 observations (eXMC) |
| Parameters frozen at model build | Parameters track drift in real time from sensor data (smc_ex O-SMC²) |
| Analyst picks which inputs matter | BART discovers which 5 of 50 inputs drive output (StochTree-Ex) |
| Output CI from replications only | Output CI includes epistemic uncertainty over input parameters |
| Simultaneous events: FIFO | Simultaneous events: causal ordering via tick-diasca |

Arena and AnyLogic have 30 years of domain libraries and 3D animation.
We don't replace them. We add the statistical brain they don't have.

## Les Quatre Probabileurs

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
