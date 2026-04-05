# TODO

Open tasks for sim_ex. Pick one, open a PR. No issue required.

## Good First Issues

- [ ] **Property-based tests: Little's Law** — for any stable M/M/c queue, `L = lambda * W`. Generate random (lambda, mu, c) triples, run 10K time units, assert the invariant within 5%. StreamData or hand-rolled.
- [ ] **Property-based tests: flow conservation** — parts in = parts out + parts in system. Every entity that `arrive`s must eventually `depart` or be accounted for at simulation end.
- [ ] **`assign` with dynamic values** — currently `assign :priority, :normal` sets a constant. Support `assign :priority, fn -> Enum.random([:low, :normal, :high]) end` for runtime evaluation.
- [ ] **More distribution types** — `uniform(a, b)`, `triangular(a, m, b)`, `lognormal(mu, sigma)` in the DSL. Add to `Sim.DSL.Process.sample/2` and the Rust NIF engine.
- [ ] **Dialyzer specs** — add `@spec` to public functions in `Sim`, `Sim.Warmup`, `Sim.TimeSeries`, `Sim.Validate`, `Sim.Experiment`. Run `mix dialyzer` clean.

## Engine Improvements

- [ ] **Preemptive resources** — `seize :machine, preempt: true` ejects the current holder (Arena PREEMPT). Needs priority field on requests and a `preempt_handler` callback on `DSL.Resource`.
- [ ] **Conveyor / transport delay** — `transport :conveyor, from: :a, to: :b` with configurable speed and accumulation. Common in manufacturing, missing from most open-source DES.
- [ ] **Warm-up auto-detection in Engine** — wire `Sim.Warmup.detect/2` into the engine loop so steady-state statistics are collected automatically after truncation.
- [ ] **LiveDashboard integration** — a `Phoenix.LiveDashboard` page showing real-time entity counts, queue lengths, utilization gauges. sim_ex already collects the data; this is the UI.

## DSL Extensions

- [ ] **`inspect` verb** — `inspect :queue_length` prints or logs the current state mid-flow. Debugging aid.
- [ ] **`signal` / `wait`** — inter-process synchronization (Arena SIGNAL/WAIT). Entity A signals, Entity B unblocks.
- [ ] **Conditional `seize`** — `seize :machine, when: fn state -> state.attrs[:priority] == :high end`. Skip if condition fails.
- [ ] **`store` / `unstore`** — temporary holding areas (Arena STORE). Parts wait without holding a resource.

## Analysis

- [ ] **Trace output format** — structured event log (CSV or Parquet via Explorer) for post-hoc analysis. Every event: `{tick, entity, event_type, duration, queue_length}`.
- [ ] **Animation data export** — export entity movements as JSON timeline for browser visualization. No 3D — just a Gantt chart of resource usage over time.
- [ ] **Batch means confidence intervals** — `Sim.Statistics` has Welford; add Schmeiser's batch means for long-run CI without replications.

## Documentation

- [ ] **Hex docs** — publish to hexdocs.pm. Current `ex_doc` config works, just needs `mix hex.publish`.
- [ ] **Tutorial: M/M/c queue** — step-by-step guide from `mix new` to steady-state CI. Target audience: someone who has never used Elixir.
- [ ] **Tutorial: custom Entity** — build a machine with breakdowns from scratch using `@behaviour Sim.Entity`.
- [ ] **Benchmark reproduction guide** — document exact hardware, OS, OTP version, flags for reproducing published numbers.

## Integration

- [ ] **eXMC posterior propagation** — `Sim.Experiment.replicate/3` draws service time parameters from an eXMC posterior trace instead of fixed distributions. The "simulation that learns" pattern.
- [ ] **smc_ex online calibration** — particle filter updates simulation parameters from streaming sensor data. Digital twin use case.
- [ ] **Explorer/Polars output** — return simulation results as Explorer DataFrames instead of maps. Better for downstream analysis.

## Rust NIF Engine

- [ ] **`decide` verb in Rust** — currently only seize/hold/release/depart. Add probabilistic branching.
- [ ] **`batch` / `split` / `combine` in Rust** — fork-join patterns for the NIF engine.
- [ ] **Batch replications NIF** — run N replications in one NIF call, return all results. The "345ms for 1000 reps" pattern.
- [ ] **WASM target** — compile the Rust engine to WASM for browser-based simulation. Same DSL, runs in the browser.

## Won't Do (and Why)

- **3D animation** — Arena and AnyLogic own this. We add the statistical brain, not the visual body.
- **GUI model builder** — drag-and-drop defeats the DSL's purpose. The code IS the model.
- **Python bindings** — SimPy exists. If you want Python, use SimPy. We are the BEAM alternative.
