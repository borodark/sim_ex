# Changelog

## 0.1.2 (2026-04-05)

Three features, property tests, honest benchmarks.

- Rust NIF: all 12 verbs (decide, batch, split, combine, route, label, assign, decide_multi)
- Preemptive resources: `seize :machine, priority: :priority, preemptive: true`
- Property-based tests: Little's Law, flow conservation, determinism, edge cases
- Fixed `Resource.busy_time` bug (utilization was always 0.0)
- Re-benchmarked: SimPy race 1.8-2.9x Elixir, 10-14x Rust (honest re-run, SimPy improved)
- 112 tests, 0 failures

## 0.1.1 (2026-04-05)

Production analysis features and SimPy head-to-head benchmark.

- `assign` verb — set attributes on entity instances mid-flow
- `Sim.Warmup` — Welch's method warm-up detection and truncation
- `Sim.TimeSeries` — per-window statistics (utilization, throughput, queue length by shift)
- `Sim.Validate` — compare simulation to historical data (KS test, error metrics, verdict)
- SimPy head-to-head benchmark: 1.9x Elixir, 14x Rust on batch replications
- 77 tests, 0 failures

## 0.1.0 (2026-04-01)

Initial release.

- Core DES engine: Clock, Calendar, Entity behaviour, EntityManager
- Five execution modes: Engine (tight loop, 533K E/s), ETS, Diasca, Parallel, Rust NIF (9.2M E/s)
- Tick-diasca engine: causal ordering via `{tick, diasca}` timestamps (Sim-Diasca pattern)
- DSL for subject matter experts: 11 GPSS/Arena-style verbs (arrive, seize, hold, release, depart, decide, batch, label, route, split, combine) with multi-form arrive and decide
- DSL scheduling: time-varying resource capacity and non-stationary arrivals
- Multi-way probabilistic routing, fork-join (split/combine), assembly batching
- DSL.Resource: seize/release protocol with capacity management
- DSL.Process: macro compiler — process flows to Entity modules
- ETS-based Topology for shared state (InterSCSimulator pattern)
- Resource: capacity-limited servers with FIFO queues
- Source: configurable arrival generators (float and diasca modes)
- PHOLD: standard DES benchmark entity
- Statistics: Welford streaming mean/variance, batch means CI
- Experiment: replications with common random numbers, paired comparison
- Zero runtime dependencies for Elixir engines (pure Elixir + OTP). Rust toolchain required for NIF engine.
- 61 tests, 0 failures
