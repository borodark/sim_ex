# Changelog

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
