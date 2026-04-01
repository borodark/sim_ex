# Changelog

## 0.1.0 (2026-04-01)

Initial release.

- Core DES engine: Clock, Calendar, Entity behaviour, EntityManager
- Two execution modes: Engine (tight loop, 539K events/sec) and GenServer (interactive)
- Tick-diasca engine: causal ordering via `{tick, diasca}` timestamps (Sim-Diasca pattern)
- DSL for subject matter experts: GPSS/Arena-style `seize`/`hold`/`release` syntax
- DSL.Resource: seize/release protocol with capacity management
- DSL.Process: macro compiler — process flows to Entity modules
- ETS-based Topology for shared state (InterSCSimulator pattern)
- Resource: capacity-limited servers with FIFO queues
- Source: configurable arrival generators (float and diasca modes)
- PHOLD: standard DES benchmark entity
- Statistics: Welford streaming mean/variance, batch means CI
- Experiment: replications with common random numbers, paired comparison
- Zero dependencies (pure Elixir + OTP)
- 26 tests, 0 failures
