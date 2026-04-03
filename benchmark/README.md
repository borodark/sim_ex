# sim_ex Benchmark Suite

Five benchmarks, each answering a different question about the engine.

## Quick Start

```bash
# Smoke test (60 seconds)
mix run benchmark/full_bench.exs -- quick

# Full suite (15 minutes)
mix run benchmark/full_bench.exs

# With NUMA scheduler pinning (recommended for production-accurate numbers)
elixir --erl "+sbt tnnps" -S mix run benchmark/full_bench.exs
```

## The Benchmarks

### 1. `phold_bench.exs` — Standard DES Benchmark

**Question:** What is the raw event throughput at different entity counts?

PHOLD is the standard synthetic benchmark for DES engines since the 1980s.
Each logical process receives a ping, does nothing useful, and sends a
ping to a random LP. What matters is not the computation — there is none
— but the infrastructure: pop, lookup, dispatch, insert, repeat.

```bash
mix run benchmark/phold_bench.exs
```

Sweeps: 100 → 10K LPs, remote fraction 0.10/0.25/0.50.

**Reference:** ROSS achieves 1.4-1.8M events/sec single-node (C/MPI).

### 2. `engine_vs_genserver.exs` — Architecture A/B Test

**Question:** What does the GenServer abstraction cost in the hot path?

Runs the same PHOLD workload through both Engine mode (tight loop, zero
message passing) and GenServer mode (Calendar + EntityManager as
processes). The speedup is the cost of the actor model in the inner loop.

```bash
mix run benchmark/engine_vs_genserver.exs
```

Expected: 2-8x speedup for Engine over GenServer.

### 3. `ets_ab.exs` — Map vs ETS Entity Storage

**Question:** At what entity count does ETS outperform Map?

Map uses persistent HAMT (O(log32 N) lookup, path-copy on update, creates
garbage). ETS uses mutable hash table (O(1) lookup, in-place update, no
garbage on the process heap). The crossover depends on GC pressure and
NUMA scheduler binding.

```bash
mix run benchmark/ets_ab.exs

# With tnnps (changes the crossover point):
elixir --erl "+sbt tnnps" -S mix run benchmark/ets_ab.exs
```

Expected: Map wins at <1K entities. ETS wins at 100K+ with tnnps.

### 4. `full_bench.exs` — Comprehensive Suite

**Question:** Everything. Throughput, memory, accuracy, scaling.

Six sections:
1. PHOLD scaling (100 → 100K LPs)
2. Factory model (10 → 400 machines)
3. M/M/1 statistical accuracy (rho 0.1 → 0.95 vs Erlang theory)
4. Engine vs Diasca mode comparison
5. Calendar pressure (4K → 256K pending events)
6. Memory profile (per-entity overhead)

```bash
# Quick smoke (60 seconds)
mix run benchmark/full_bench.exs -- quick

# Full suite (15 minutes)
mix run benchmark/full_bench.exs

# With scheduler pinning
elixir --erl "+sbt tnnps" -S mix run benchmark/full_bench.exs
```

### 5. `dsl_complexity_bench.exs` — DSL Verb Complexity Impact

**Question:** How much does DSL complexity cost?

Runs six models of increasing verb complexity — from barbershop (5 verbs)
to full electronics fab (split+decide+combine+batch) — and measures
events/sec for each.

```bash
mix run benchmark/dsl_complexity_bench.exs
```

Expected: 100K-800K E/s depending on model complexity. The complexity
tax is 2-8x, not 100x.

## Interpreting Results

**Events/sec** — the headline metric. Higher is better. Depends on:
- Entity count (Map lookup scales with N)
- Events per entity per tick (calendar depth)
- Verb complexity (split/combine/batch add bookkeeping)
- Engine mode (Rust >> Engine >> ETS >> GenServer)

**Load average** — reported in `full_bench.exs`. The Engine is single-
threaded: load ~1.0 on 88 cores. This is by design. The parallel engine
uses more cores but at modest speedup for cheap-event workloads.

**Memory** — reported as per-entity overhead. ~275 bytes/entity in the
Map engine. ETS uses less process heap but more total memory.

**M/M/1 accuracy** — simulation vs Erlang theory. Should be within 5%
at all utilization levels. If not, the engine is broken.

## Hardware Notes

Results vary significantly by:
- **CPU architecture** — the Xeon E5-2699 v4 (88 cores) used for
  published numbers has large L3 cache that helps at 10K+ entities
- **NUMA topology** — `+sbt tnnps` changes ETS vs Map crossover
- **Rust toolchain** — Rust NIF performance depends on release build
  optimization level (always `--release`, which Rustler does by default)

## Published Numbers

All numbers in README.md, CHANGELOG.md, and the book were measured on:
- x86_64-pc-linux-gnu, 88 cores (dual Xeon E5-2699 v4)
- OTP 27, Elixir 1.18.3
- Rust 1.83 (Rustler 0.36)

Re-run on your hardware to get your numbers. The ratios (Engine/GenServer,
Elixir/Rust) are more portable than the absolute values.
