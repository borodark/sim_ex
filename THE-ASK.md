# Elixir in Simulators: BEAM as a Discrete-Event Simulation Engine

*An assessment of the BEAM virtual machine for writing simulators,
grounded in Averill Law's methodology, with Les Trois Chambrées
providing the statistical backbone.*

## The Thesis

Every textbook concept in discrete-event simulation has a direct OTP
equivalent. The mapping is not metaphorical — it is structural. Where
Arena uses an event calendar, BEAM uses process mailboxes. Where AnyLogic
uses Java threads for entities, BEAM uses lightweight processes that cost
2KB each. Where Simio uses a simulation clock, BEAM can use a GenServer
holding monotonic virtual time. The question is not whether BEAM *can*
simulate — Sim-Diasca at EDF proved that in 2010 with millions of
concurrent actors. The question is whether BEAM + Les Trois Chambrées
creates something no existing engine offers: a simulator that learns.

## Averill Law's Framework → OTP

Averill M. Law's *Simulation Modeling and Analysis* (6th ed., 2024,
178,000+ copies, 23,700 citations) defines the field. His 7-step
methodology for simulation studies maps to BEAM/OTP as follows:

### Step 1: Problem Formulation → Application.start/2

Law insists on documenting objectives, scope, and performance measures
before writing code. In OTP terms: the Application module. The
`application/0` callback defines what supervisors start. The supervision
tree *is* the problem formulation — it declares which entities exist,
how they relate, and what happens when one fails.

### Step 2: Conceptual Model → Behaviours + Protocols

Law's "assumptions document" — the detailed report of model concepts,
algorithms, and data flows — maps to Elixir behaviours and protocols.
A `@behaviour SimEntity` declares the contract: `init/1`, `handle_event/2`,
`state/1`. A protocol `Schedulable` defines what can be placed on the
event calendar. The conceptual model is executable.

```elixir
defmodule SimEntity do
  @callback init(config :: map()) :: {:ok, state :: term()}
  @callback handle_event(event :: term(), state :: term()) ::
    {:ok, new_state :: term(), events :: [event()]}
  @callback statistics(state :: term()) :: map()
end
```

### Step 3: Input Modeling → Les Trois Chambrées

This is where the ecosystem pays off.

Law devotes 80 pages to input modeling: fitting probability distributions
to real-world data (his ExpertFit software tests 40 distributions). The
traditional approach: collect data → fit distribution → freeze parameters
→ run simulation. The Bayesian approach:

| Traditional (Law/ExpertFit) | Bayesian (Les Trois Chambrées) |
|---|---|
| Point estimate of distribution params | Full posterior over params (eXMC) |
| Fit once before simulation | Update params during simulation (smc_ex) |
| Test 40 parametric families | Nonparametric discovery of input structure (StochTree-Ex) |
| Goodness-of-fit test | Posterior predictive check |
| Fixed inter-arrival times | Posterior-sampled inter-arrival times |

**eXMC** (NUTS/HMC): fits complex parametric input models offline.
Service time = Weibull? Fit the posterior over shape and scale, propagate
uncertainty into simulation output.

**smc_ex** (O-SMC²): online input model calibration. As simulation runs
and real data arrives, particle filters track parameter drift. The
"self-calibrating simulation" that no commercial engine offers.

**StochTree-Ex** (BART): when you have 50 potential input variables and
no theory about which matter, BART discovers the functional form. Feed
its variable importance into the simulation's input model.

### Step 4: Model Translation → GenServer + Supervisor

Law's "computer program" phase. Each simulation entity becomes a process:

```elixir
# A machine in a job shop simulation
defmodule Machine do
  use GenServer

  defstruct [:id, :status, :current_job, :queue, :stats]

  def init(config) do
    {:ok, %Machine{
      id: config.id,
      status: :idle,
      queue: :queue.new(),
      stats: %{busy_time: 0, jobs_completed: 0}
    }}
  end

  def handle_cast({:arrive, job, clock}, state) do
    case state.status do
      :idle ->
        service_time = sample_service_time(state)
        schedule_departure(state.id, job, clock + service_time)
        {:noreply, %{state | status: :busy, current_job: job}}
      :busy ->
        {:noreply, %{state | queue: :queue.in(job, state.queue)}}
    end
  end

  def handle_cast({:depart, _job, clock}, state) do
    case :queue.out(state.queue) do
      {{:value, next_job}, queue} ->
        service_time = sample_service_time(state)
        schedule_departure(state.id, next_job, clock + service_time)
        {:noreply, %{state | queue: queue, current_job: next_job,
          stats: update_stats(state.stats, clock)}}
      {:empty, _} ->
        {:noreply, %{state | status: :idle, current_job: nil,
          stats: update_stats(state.stats, clock)}}
    end
  end
end
```

The supervision tree mirrors the physical system:

```
Application
├── SimClock (GenServer — virtual time)
├── EventCalendar (GenServer — priority queue of future events)
├── EntitySupervisor (DynamicSupervisor)
│   ├── Machine.1
│   ├── Machine.2
│   ├── ...
│   └── Machine.n
├── SourceSupervisor
│   ├── CustomerSource.1 (generates arrivals)
│   └── CustomerSource.2
├── StatisticsCollector (GenServer — Welford online stats)
└── OutputAnalyzer (GenServer — confidence intervals)
```

### Step 5: Verification & Validation → OTP Patterns

Law's verification ("does the program implement the model correctly?")
maps directly to:

- **Dialyzer**: type checking against behaviour specs
- **ExUnit**: property-based testing of entity logic
- **Supervisor restart counts**: if an entity crashes, the system heals
  rather than producing garbage output
- **`:sys.trace`**: built-in tracing of any GenServer, no instrumentation needed
- **Hot code reload**: fix a bug in one entity type while simulation runs

Law's validation ("does the model represent reality?") maps to:

- **Posterior predictive checks** (eXMC): simulate from fitted model,
  compare to real data
- **Online residuals** (smc_ex): particle filter's effective sample size
  tells you when model diverges from reality
- **Feature importance** (StochTree-Ex): are the right variables driving
  simulation output?

### Step 6: Experimental Design → Distributed Erlang

Law covers common random numbers (CRN), antithetic variates, and
ranking-and-selection procedures for comparing system configurations.

BEAM's distribution model makes this natural:

```elixir
# Run 30 replications across a cluster
nodes = Node.list()
results = nodes
  |> Enum.flat_map(fn node ->
    1..10 |> Enum.map(fn rep ->
      Task.Supervisor.async({TaskSup, node}, fn ->
        Simulation.run(config, seed: rep)
      end)
    end)
  end)
  |> Task.await_many(timeout: :infinity)

# Ranking and selection: which config is best?
Experiment.welch_test(results_a, results_b)
```

Common random numbers: same `:rand` seed produces same entity trajectories.
Antithetic variates: negate the uniform draws. Both trivial when PRNG
state is explicit (which `:rand` is — functional state, no global mutable).

### Step 7: Output Analysis → eXMC + Telemetry

Law's output analysis distinguishes:

1. **Terminating simulations**: run until natural end, replicate, build
   confidence intervals across replications.
2. **Steady-state simulations**: delete initial transient (warmup), then
   batch means or regenerative method.

BEAM provides `:telemetry` for streaming output collection and eXMC
provides the statistical machinery:

```elixir
# Streaming Welford statistics (no storage of raw data)
defmodule OutputAnalyzer do
  use GenServer

  def handle_cast({:observation, metric, value}, state) do
    state = update_welford(state, metric, value)
    if state.n[metric] >= state.batch_size do
      emit_batch_mean(metric, state)
    end
    {:noreply, state}
  end

  def confidence_interval(metric, alpha \\ 0.05) do
    # t-distribution CI from batch means
    GenServer.call(__MODULE__, {:ci, metric, alpha})
  end
end
```

For the full Bayesian treatment: fit a hierarchical model over
replication outputs with eXMC. Each replication is a "group" in the
hierarchy. Partial pooling across replications gives tighter CIs than
classical methods when replications are expensive.

## The Next-Event Time Advance on BEAM

Law's simulation clock advances discretely from event to event. Two
implementation strategies on BEAM:

### Strategy A: Centralized Calendar (simple, correct)

```elixir
defmodule EventCalendar do
  use GenServer

  # Priority queue keyed by virtual time
  defstruct calendar: :gb_trees.empty(), clock: 0.0

  def schedule(time, event) do
    GenServer.cast(__MODULE__, {:schedule, time, event})
  end

  def handle_cast(:advance, state) do
    case :gb_trees.smallest(state.calendar) do
      {time, event} ->
        calendar = :gb_trees.delete(time, state.calendar)
        dispatch(event)  # send to target entity process
        {:noreply, %{state | calendar: calendar, clock: time}}
    end
  end
end
```

Entities don't manage their own time — the calendar drives everything.
Simple, deterministic, debuggable. Works for millions of events/second
on a single node.

### Strategy B: Distributed Virtual Time (Sim-Diasca pattern)

For massive scale: each entity holds its own clock. Synchronization
via Chandy-Misra-Bryant or Time Warp (optimistic). Sim-Diasca at EDF
proved this works on Erlang with millions of actors across clusters.

The tradeoff: Strategy A is simpler and sufficient for most models.
Strategy B scales to millions of concurrent entities across nodes but
adds synchronization complexity.

## What Les Trois Chambrées Add That No Engine Has

### 1. Posterior-Propagated Uncertainty

Traditional simulation: sample input from fitted distribution, run,
collect output. The input distribution parameters are treated as known.

Bayesian simulation: sample parameters from posterior, then sample
inputs, run, collect output. The output distribution includes both
aleatory uncertainty (random variation) AND epistemic uncertainty
(parameter uncertainty). This is what Law calls "input uncertainty
analysis" — and acknowledges is rarely done because it's hard. With
eXMC, it's one extra loop.

### 2. Self-Calibrating Digital Twins

smc_ex's O-SMC² enables something no commercial engine offers:
a simulation that updates its own parameters as real-world data streams
in. The simulation twin isn't frozen at commissioning — it tracks
reality via particle filtering.

```elixir
# Digital twin that self-calibrates
defmodule DigitalTwin do
  use GenServer

  def init(config) do
    {:ok, %{
      model: config.simulation_model,
      filter: SMC.ParticleFilter.init(config.prior, particles: 1000),
      clock: 0.0
    }}
  end

  def handle_cast({:sensor_reading, reading, timestamp}, state) do
    # Update beliefs about simulation parameters
    filter = SMC.ParticleFilter.step(state.filter, reading)

    # Run simulation forward with updated parameters
    params = SMC.ParticleFilter.estimate(filter)
    forecast = Simulation.run_from(state.model, params, timestamp)

    broadcast_forecast(forecast)
    {:noreply, %{state | filter: filter, clock: timestamp}}
  end
end
```

### 3. Automatic Metamodeling

When a simulation has 50 input parameters and each run takes minutes,
you can't explore the full space. StochTree-Ex BART builds a metamodel:

1. Run N simulation experiments (Latin hypercube design)
2. Fit BART: `StochTree.BART.fit(inputs, outputs)`
3. Get variable importance: which 5 of 50 inputs matter?
4. Get partial dependence: what's the functional form?
5. Focus expensive simulation runs on the important region

This replaces ad-hoc sensitivity analysis with principled nonparametric
discovery.

## Prior Art: BEAM for Simulation

| Project | Scale | What |
|---------|-------|------|
| **Sim-Diasca** (EDF, 2010) | Millions of actors | Generic DES engine, LGPL, Erlang. Parallel, distributed. Used by Électricité de France for energy grid simulation. |
| **InterSCSimulator** | Millions of agents | Smart city traffic simulation in Erlang. |
| **ErlangTW** | Research | Time Warp parallel simulation middleware on Erlang. |
| **Events** (pbayer) | Small | Elixir DES framework on GitHub. |
| **Game server @ 10K/30Hz** | 10K entities | Elixir Forum report: real-time entity simulation at 30Hz tick rate. |

The precedent exists. What's missing is the statistical layer — and
that's exactly what Les Trois Chambrées provide.

## Architecture: sim_ex

A new library completing the quartet:

```
sim_ex/
├── lib/
│   ├── sim.ex                    # Public API
│   ├── sim/
│   │   ├── clock.ex              # Virtual time GenServer
│   │   ├── calendar.ex           # Event priority queue
│   │   ├── entity.ex             # @behaviour for simulation entities
│   │   ├── source.ex             # Arrival generators
│   │   ├── resource.ex           # Servers, machines, queues
│   │   ├── statistics.ex         # Welford online + batch means
│   │   ├── experiment.ex         # CRN, replication, ranking/selection
│   │   ├── input_model.ex        # Bridge to eXMC for input fitting
│   │   └── output_analysis.ex    # Confidence intervals, warmup detection
│   └── sim/connectors/
│       ├── anylogic.ex           # AnyLogic Cloud REST (from sidecar)
│       └── csv.ex                # Import/export trace data
├── test/
├── benchmark/
├── notebooks/
│   ├── 01_mm1_queue.livemd       # M/M/1 queue (Law Ch. 1 example)
│   ├── 02_job_shop.livemd        # Job shop with breakdowns
│   └── 03_self_calibrating.livemd # Digital twin + smc_ex
└── mix.exs
```

Dependencies: zero for core DES. Optional: `{:exmc, ...}` for input
modeling, `{:smc_ex, ...}` for online calibration, `{:stochtree_ex, ...}`
for metamodeling.

## Law's Classical Examples on BEAM

### M/M/1 Queue (Law, Chapter 1)

The simplest useful simulation. Single server, Poisson arrivals,
exponential service:

```elixir
# 50 lines of Elixir vs 200+ in C/Fortran
{:ok, sim} = Sim.new()
|> Sim.add_source(:arrivals, distribution: :exponential, mean: 1.0)
|> Sim.add_resource(:server, capacity: 1,
     service: [distribution: :exponential, mean: 0.5])
|> Sim.connect(:arrivals, :server)
|> Sim.run(until: 10_000)

Sim.statistics(sim, :server)
# %{utilization: 0.497, mean_wait: 0.48, mean_queue: 0.96}
```

### Job Shop with Bayesian Input (Law, Chapter 2)

Five machine groups, three job types, random routing. But instead of
Law's fixed exponential distributions:

```elixir
# Fit service time posteriors from real shop floor data
posterior = Exmc.sample(service_time_model, shop_floor_data,
  num_samples: 2000, num_warmup: 1000)

# Propagate parameter uncertainty through simulation
results = for _ <- 1..100 do
  # Sample one parameter set from posterior
  params = Exmc.Predictive.sample_prior(posterior)
  Sim.run(job_shop_model(params), until: 480 * 20)  # 20 days
end

# Output CI includes both aleatory + epistemic uncertainty
Sim.OutputAnalysis.confidence_interval(results, :mean_flowtime)
```

## Why This Matters

The simulation industry is split:

1. **Commercial engines** (AnyLogic, Simio, Arena): excellent GUI, drag-and-drop
   modeling, animation, but statistical inference is an afterthought.
   Calibration = genetic algorithm. Uncertainty = Monte Carlo with
   fixed distributions. No streaming update. No posteriors.

2. **Code-based frameworks** (SimPy, Salabim, JaamSim): more flexible,
   but single-threaded (Python GIL), no fault tolerance, no distribution,
   no built-in statistical inference.

3. **Academic PDES** (Sim-Diasca, ROSS, SPEEDES): parallel/distributed,
   but no statistical layer, complex setup, limited user base.

BEAM + Les Trois Chambrées occupies the empty quadrant:
**programmatic, concurrent, fault-tolerant, statistically rigorous.**

The simulation that learns from data while it runs. The digital twin
that updates its own parameters. The metamodel that discovers what
matters. This is what Averill Law's framework becomes when you build
it on a platform designed for millions of concurrent, communicating,
fault-tolerant processes.

## References

- Law, A.M. (2024). *Simulation Modeling and Analysis*, 6th ed. McGraw-Hill.
- Law, A.M. (2003). "How to Conduct a Successful Simulation Study." WSC 2003.
- Sim-Diasca: https://github.com/Olivier-Boudeville-EDF/Sim-Diasca
- Fujimoto, R. (2000). *Parallel and Distributed Simulation Systems*. Wiley.
- Chandy, K.M. & Misra, J. (1979). "Distributed Simulation." ACM Computing Surveys.
- Jefferson, D. (1985). "Virtual Time." ACM TOPLAS, 7(3).
- Chopard, B. et al. (2018). "Parallel Discrete Event Simulation with Erlang." arXiv:1206.2775.
- InterSCSimulator: Erlang agent-based smart city simulation.
