# TODO

Open tasks for sim_ex. Pick one, open a PR. No issue required.

## Good First Issues

- [ ] **`assign` with dynamic values** — currently `assign :priority, :normal` sets a constant. Support `assign :priority, fn -> Enum.random([:low, :normal, :high]) end` for runtime evaluation.
- [ ] **More distribution types** — `triangular(a, m, b)`, `lognormal(mu, sigma)` in the DSL. Add to `Sim.DSL.Process.sample/2` and the Rust NIF engine.
- [ ] **Dialyzer specs** — add `@spec` to public functions in `Sim`, `Sim.Warmup`, `Sim.TimeSeries`, `Sim.Validate`, `Sim.Experiment`. Run `mix dialyzer` clean.
- [ ] **`@doc` on Source and Resource** — `Sim.Source` and `Sim.Resource` have `@moduledoc` but no `@doc` on public functions. Add function-level docs for Hex.

## Engine Improvements

- [ ] **Accumulating conveyor (Phase 2)** — `conveyor :belt, accumulating: true` blocks upstream items when exit is blocked. Back-pressure propagation. Phase 1 (capacity-limited delay) is done.
- [ ] **Warm-up auto-detection in Engine** — wire `Sim.Warmup.detect/2` into the engine loop so steady-state statistics are collected automatically after truncation.
- [ ] **LiveDashboard integration** — a `Phoenix.LiveDashboard` page showing real-time entity counts, queue lengths, utilization gauges. sim_ex already collects the data; this is the UI.
- [ ] **Guard against spurious release** — `proper_statham` found that releasing an ungranted job was silently accepted. Fixed for preemptive resources; the non-preemptive `busy > 0` guard should also track job IDs for a stronger check.
- [ ] **Deadlock detection** — circular seize dependencies cause infinite wait. Detect and report.
- [ ] **`transport` in Rust NIF** — `Step::Transport(length, speed, capacity)` for the Rust engine. Phase 1 conveyor is Elixir-only.

## DSL Extensions

- [ ] **`inspect` verb** — `inspect :queue_length` prints or logs the current state mid-flow. Debugging aid.
- [ ] **`signal` / `wait`** — inter-process synchronization (Arena SIGNAL/WAIT). Entity A signals, Entity B unblocks.
- [ ] **Conditional `seize`** — `seize :machine, when: fn state -> state.attrs[:priority] == :high end`. Skip if condition fails.
- [ ] **`store` / `unstore`** — temporary holding areas (Arena STORE). Parts wait without holding a resource.
- [ ] **`on_preempt:` label** — when a preempted entity should jump to a custom handler instead of re-queuing. DSL syntax exists (`seize :m, on_preempt: :handler`), handler dispatch not yet wired.

## Testing

- [ ] **Upgrade PropCheck generators** — replace `such_that` with custom generators for better shrinking. Current `mm1_params` rejects ~40% of generated configs.
- [ ] **proper_statham: event injection** — add `schedule_event` command to the engine statem model. Generate adversarial events for non-existent entities (tests orphan event handling).
- [ ] **proper_statham: circular seize** — model two resources with cross-dependency. Verify engine detects or survives deadlock.
- [ ] **Benchmark reproduction guide** — document exact hardware, OS, OTP version, load average for reproducing published numbers.

## Analysis

- [ ] **Trace output format** — structured event log (CSV or Parquet via Explorer) for post-hoc analysis. Every event: `{tick, entity, event_type, duration, queue_length}`.
- [ ] **Animation data export** — export entity movements as JSON timeline for browser visualization. No 3D — just a Gantt chart of resource usage over time.
- [ ] **Batch means confidence intervals** — `Sim.Statistics` has Welford; add Schmeiser's batch means for long-run CI without replications.

## Documentation

- [ ] **Hex publish** — publish to hex.pm. `mix.exs` is ready, just needs `mix hex.publish`.
- [ ] **Tutorial: M/M/c queue** — step-by-step guide from `mix new` to steady-state CI. Target audience: someone who has never used Elixir.
- [ ] **Tutorial: custom Entity** — build a machine with breakdowns from scratch using `@behaviour Sim.Entity`.
- [ ] **Tutorial: conveyor model** — PCB assembly line with two conveyors, soldering, inspection, rework. Shows `transport` + `decide` + `seize`/`release` composing.

## Integration

- [ ] **eXMC posterior propagation** — `Sim.Experiment.replicate/3` draws service time parameters from an eXMC posterior trace instead of fixed distributions. The "simulation that learns" pattern.
- [ ] **smc_ex online calibration** — particle filter updates simulation parameters from streaming sensor data. Digital twin use case.
- [ ] **Explorer/Polars output** — return simulation results as Explorer DataFrames instead of maps. Better for downstream analysis.

## Rust NIF Engine

- [ ] **Batch replications NIF** — run N replications in one NIF call, return all results. Eliminates Task dispatch overhead for large N.
- [ ] **WASM target** — compile the Rust engine to WASM for browser-based simulation. Same DSL, runs in the browser.

## Done (v0.1.3)

- [x] Property-based tests: Little's Law, flow conservation, determinism, edge cases (PropCheck + hand-rolled hybrid)
- [x] proper_statham: stateful property testing (engine, resource isolation, adversarial preemptive) — found spurious-release bug
- [x] Preemptive resources: `seize :machine, priority: :priority, preemptive: true` with generation counter
- [x] Conveyor/transport verb: `conveyor :belt, length: 100, speed: 10, capacity: 20` + `transport :belt`
- [x] Rust NIF: all 12 verbs (decide, batch, split, combine, route, label, assign, decide_multi)
- [x] Parallel replications by default: `Sim.Experiment.replicate` uses all cores (30x vs SimPy)
- [x] Fixed `Resource.busy_time` bug (utilization was always 0.0)
- [x] Fixed spurious-release bug (releases > grants on ungranted release)
- [x] Honest benchmarks with load average reporting

## Won't Do (and Why)

- **3D animation** — Arena and AnyLogic own this. We add the statistical brain, not the visual body.
- **GUI model builder** — drag-and-drop defeats the DSL's purpose. The code IS the model.
- **Python bindings** — SimPy exists. If you want Python, use SimPy. We are the BEAM alternative.
