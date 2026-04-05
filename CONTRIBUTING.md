# Contributing to sim_ex

sim_ex is a discrete-event simulation engine for the BEAM. Contributions
welcome — from typo fixes to new engine modes.

## Getting Started

```bash
git clone https://github.com/borodark/sim_ex.git
cd sim_ex
mix deps.get
mix test          # 77 tests, should all pass
```

The Rust NIF engine requires a Rust toolchain (`rustup`). If you don't
have one, the Elixir engines still work — just skip `mode: :rust` tests.

## What to Work On

See [TODO.md](TODO.md). "Good First Issues" are tagged for newcomers.
No issue required — just open a PR.

## Code Style

- Pattern matching over `if`/`case` chains where possible
- Thread PRNG state explicitly (`:rand` state in entity, not global)
- No runtime dependencies for core engines
- Tests use deterministic seeds — same seed, same trajectory

## Running Tests

```bash
mix test                          # full suite
mix test test/features_test.exs   # just the new features
mix test --only dsl               # DSL tests
```

## Running Benchmarks

```bash
mix run benchmark/full_bench.exs -- quick    # 60-second smoke
mix run benchmark/phold_bench.exs            # PHOLD sweep
mix run benchmark/ets_ab.exs                 # Map vs ETS
```

## Architecture

The codebase has clear layers:

1. **Entity behaviour** (`lib/sim/entity.ex`) — the contract
2. **Engines** (`lib/sim/engine.ex`, `engine/ets.ex`, `engine/diasca.ex`) — execution strategies
3. **DSL** (`lib/sim/dsl.ex`, `dsl/process.ex`, `dsl/resource.ex`) — macro compiler
4. **Analysis** (`lib/sim/statistics.ex`, `warmup.ex`, `validate.ex`) — output processing
5. **Rust NIF** (`native/sim_nif/`) — high-performance engine for batch workloads

New verbs go in the DSL layer. New engines implement the same entity dispatch.
New analysis tools are standalone modules with no engine coupling.

## Pull Requests

- One feature per PR
- Include tests — we don't merge without them
- Benchmark if it touches the hot path
- Update CHANGELOG.md

## License

By contributing, you agree your code is licensed under Apache-2.0.
