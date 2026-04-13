# Erlang 2026 Workshop Submission

**Title (working):**
sim_ex: Verifying a Concurrent DES Library with PropEr — Inter-Engine Equivalence, Causal Ordering, and the Bug 700 Sequences Found

**Venue:** 25th ACM SIGPLAN Erlang Workshop @ ICFP 2026, Indiana University Indianapolis
**Submission deadline:** Thu 14 May 2026 AoE (UTC-12)
**Notification:** Wed 17 Jun 2026
**Camera-ready:** Tue 7 Jul 2026
**Workshop:** Fri 28 Aug 2026
**Submission system:** https://erlang26.hotcrp.com
**Format:** ACM SIGPLAN `acmart` (sigplan, anonymous review TBD — confirm CFP)
**Target length:** 8-12 pages (workshop)
**Aim:** 10 pages including references

---

## Abstract (draft v0)

> Discrete event simulation engines on the BEAM are not new — Sim-Diasca demonstrated million-actor simulations at EDF in 2010, and InterSCSimulator scaled urban traffic models to comparable sizes — but the verification methodology used to validate them has been almost entirely point-test driven. We present sim_ex, a multi-engine discrete event simulation library for Elixir/OTP that provides five interchangeable execution backends (centralized event calendar, ETS-shared topology, parallel, Tick-Diasca causal ordering, and a Rust NIF), a 14-verb Arena-style domain-specific language, and the first stateful property-based verification suite applied to a DES engine. We describe a three-tier testing taxonomy — point tests (the clipboard), property tests with shrinking (the auditor), and stateful command-sequence tests (the saboteur) — and report on a hybrid PropCheck + hand-rolled stochastic harness that addresses a methodological pitfall in property-based testing of stochastic systems: PropCheck shrinking chases Monte Carlo noise rather than bugs. Three `proper_statem` models generate adversarial command sequences against the engine, the resource protocol in isolation, and a preemptive scheduling configuration; together they execute approximately 700 randomized sequences per test run. The Resource model identified a four-step sequence in which releasing an ungranted job silently corrupted resource statistics — a bug that 114 point tests and 350 property trials had missed. We extend prior work on cross-mode equivalence by formulating *inter-engine equivalence* as a property over PropEr-generated DSL models: any well-formed model executed under any of the five backends must produce observably identical trajectories under common random numbers. We discuss what this guarantee buys for the simulation practitioner, why the BEAM is uniquely well-suited to host this style of verification, and how the methodology generalizes to other concurrent systems with multiple execution strategies.

(target ~200 words; current ~290 — trim before submission)

---

## Section budget (10 pages)

| § | Title | Pages | Notes |
|---|-------|-------|-------|
| 1 | Introduction | 1.0 | Why DES on BEAM, why verification gap, the contributions list |
| 2 | sim_ex architecture | 1.5 | 5 engines, DSL, ETS topology, OTP supervision tree |
| 3 | Three-tier testing taxonomy | 1.5 | clipboard / auditor / saboteur; the methodological story |
| 4 | proper_statem models | 2.0 | Engine, Resource, Adversarial — code excerpts and postconditions |
| 5 | The found bug | 0.75 | The 4-step shrunk sequence narrative + fix |
| 6 | Inter-engine equivalence (the new contribution) | 1.5 | PropEr generators for DSL models, equivalence as property, results across 5 engines |
| 7 | Performance | 0.75 | PHOLD, SimPy comparison, parallel replication speedup |
| 8 | Related work + conclusion | 0.75 | Sim-Diasca, ROSS, ErlangTW, Quviq Erlang verification work, John Hughes PBT papers |
| - | References | 0.25 | ~25 entries |

---

## Contributions (the bullet list for §1 and abstract)

1. **A multi-engine discrete-event simulation library for the BEAM** with five interchangeable execution backends sharing a single 14-verb Arena/GPSS-style DSL. Code is open-source under Apache-2.0 (`borodark/sim_ex` v0.1.3+).

2. **A three-tier testing taxonomy** (clipboard / auditor / saboteur — point tests, property tests with shrinking, stateful command-sequence tests with shrinking) and an account of how the three tiers complement each other when verifying a stochastic concurrent system.

3. **A hybrid PropCheck + hand-rolled stochastic harness** that addresses a known methodological problem in property-based testing of stochastic systems: PropCheck's automatic shrinking, when applied to invariants of the form "observed value is within tolerance of theoretical value", chases Monte Carlo noise rather than bugs. The hybrid approach uses PropCheck shrinking for deterministic invariants (flow conservation, calendar sortedness, target validity) and a deterministic seed-based replay harness for statistical invariants (Little's Law, utilization).

4. **Three `proper_statem` models** of the sim_ex engine — full engine (Statham), resource protocol in isolation (Statham.Resource), and preemptive scheduling under adversarial workloads (Statham.Adversarial) — together generating ~700 random command sequences per test run. We document the postconditions, the model state encoding, and the symbolic-vs-dynamic phase challenges of `proper_statem` for an engine whose state cannot be carried as a symbolic variable.

5. **Three found bugs surfaced by PropEr-driven verification.**

   - **Bug #1 (Resource isolation, original work):** the four-step shrunk sequence in `Sim.Statham.Resource` showing that releasing an ungranted job silently corrupted resource statistics. Missed by the existing test suite (over a hundred point tests, several hundred property trials). Shrunk to: `init_resource(cap=3, preemptive=true) → seize(job=1, prio=3) → release(job=1) → release(job=3)`. Postcondition `grants ≥ releases` caught it.

   - **Bug #2 (Parallel engine, week 2 cross-engine probing):** running `Sim.PropertyModels.Barbershop` with `mode: :parallel` crashes immediately in `Sim.Engine.Parallel.insert_diasca_events/5` (`FunctionClauseError`). DSL-compiled processes emit float-time bare 3-tuples; the parallel engine only matches diasca-tagged events. The bug had been latent because no test in the suite had ever run a DSL model on the parallel engine. The cross-engine equivalence work surfaced it on the first probe. A naive pattern-matching bridge clause was attempted and reverted — it caused infinite diasca progression (two BEAM processes spinning at 140% CPU). The architectural fix requires entity-side tick awareness in the DSL compiler.

   - **Bug #3 (Rust NIF integration, week 2 cross-engine probing):** Barbershop with `mode: :rust` returns `{:ok, %{events: 0}}` — zero events processed instead of the expected ~600. The DSL passes `:entities` and `:stop_time`; the Rust engine wants `:resources` and `:processes` step-list form. The integration silently no-ops, *worse than a crash* because it would pass any naive smoke test that only checks for `{:ok, _}`.

   We discuss what the saboteur and the cross-engine probing found that the existing test suite — over a hundred point tests, several hundred property trials, and approximately 700 stateful sequences — had not caught.

6. **Inter-engine equivalence as three theorems.** Reading the engine sources surfaced a critical taxonomy: the five backends split into a *time group* (`:engine`, `:ets`) using float `stop_time` and a *tick group* (`:diasca`, `:parallel`, `:rust`) using integer `stop_tick` with `(tick, diasca)` two-level timestamps. This bifurcation gives the paper three distinct equivalence claims:

   - **(T1) Within-time-group equivalence.** `:engine` and `:ets` produce *strictly identical* output for any well-formed time-based scenario under the same seed. The existing 20-trial cross-mode test in `property_test.exs` is a special case; we generalize it to a normalized scenario representation and report on a 30+-trial PropEr suite. **Status: green in week 1.**

   - **(T2) Within-tick-group equivalence.** `:diasca`, `:parallel`, and `:rust` produce identical observable trajectories for any well-formed tick-based scenario under the same seed, modulo legal reordering of simultaneous events within a single `(T, D)` bucket. **This is the strongest claim of the paper** — three engines, including a cross-language Rust NIF, all agreeing on identical tick-based scenarios under PropEr-driven random workloads.

   - **(T3) Cross-group bridge.** Time-group and tick-group engines produce comparable summary statistics (arrivals, departures, mean wait) when the tick-group runs with `stop_tick = floor(stop_time)` and the same seed. Loose statistical equivalence with documented epsilon — not strict equality, because float-time and int-tick Poisson processes diverge by design.

   We report the generators, the equivalence relations, and the empirical results — including a vignette in §3 on how PropEr's shrinker rapidly surfaced the time/tick taxonomy from a property the authors initially wrote as if all five engines shared the same time semantics. The first shrunk counter-example was `{arrival_inv=3.097, service_inv=1.054, capacity=3, seed=101}`, and reading the resulting failure mode is what led to the engine taxonomy now documented in §2.

---

## What is already in the repo

### Code (production)
- `lib/sim/engine.ex` — centralized event calendar engine
- `lib/sim/engine/ets.ex` — ETS-shared topology engine
- `lib/sim/engine/parallel.ex` — parallel engine
- `lib/sim/engine/diasca.ex` — Tick-Diasca causal ordering engine
- `lib/sim/engine/rust.ex` — Rust NIF engine
- `lib/sim/dsl.ex` + `lib/sim/dsl/{process,resource,conveyor}.ex` — 14-verb DSL
- 88-core PHOLD benchmarks already published in README

### Tests (existing)
- `test/property_test.exs` — PropCheck invariants:
  - Flow conservation across `:engine` and `:ets` (50 tests)
  - Determinism: same seed → identical trajectories across `:engine` and `:ets` (30 tests)
  - **Cross-mode equivalence between `:engine` and `:ets` only** (20 tests, lines 166-178)
  - DSL flow conservation: barbershop, no_rework, all_rework, combine1, split_combine
  - Stochastic invariants via `Sim.PropertyHelper` deterministic-seed harness:
    - Little's Law within 25% (30 random M/M/1 configs)
    - Utilization within 20% of ρ (20 random M/M/1 configs)
- `test/property_models.ex` — five compiled DSL models for use as fixtures
- `test/statham_test.exs` — three `proper_statem` models:
  - **Sim.Statham**: full engine, 200 sequences, ~52% step / 30% run_n / 9% check / 9% init
  - **Sim.Statham.Resource**: resource protocol isolated, 300 sequences, found the bug
  - **Sim.Statham.Adversarial**: preemptive engine with rush+normal sources, 200 sequences

### Bug story (already documented in `statham_test.exs` lines 32-46)
The 4-step shrunk failing sequence is:
```
init_resource(capacity: 3, preemptive: true)
seize(job_id: 1, priority: 3)
release(job_id: 1)
release(job_id: 3)    ← job 3 was never seized
```
The engine accepted the spurious release silently. `busy` was clamped by `max(busy-1, 0)`, but `releases` incremented to 2 while `grants` stayed at 1. The postcondition `grants >= releases` caught it. The fix narrowed the symbolic-phase generator constraint so `release` can only be generated for actually-held job IDs, and added a `Map.has_key?(holders, job_id)` guard in the resource handler.

### Methodology insight (already in code comments, needs to be foregrounded in §3)
From `Sim.PropertyHelper` module doc:

> Hand-rolled harness for stochastic properties where PropCheck shrinking chases Monte Carlo noise.

This is the kernel of contribution #3. When the invariant is "observed sample mean is within 25% of theoretical mean", PropCheck's shrinker will reduce the run length until the empirical sample is too small for the law of large numbers to apply, producing false positives. The hybrid approach: use PropCheck's generators and `forall` for deterministic invariants where shrinking helps; use a deterministic seed-offset harness for stochastic invariants where shrinking hurts.

---

## Gap analysis (what we need to add for the paper)

### Critical (paper hinges on these)

**1. Inter-engine equivalence — restructured into three theorems.**
The original framing assumed cross-mode equivalence between `:engine` and any other backend. Reading the engine sources in week 1 revealed that the five engines split by time semantics:

- **Time group** (float `stop_time`): `:engine`, `:ets`
- **Tick group** (integer `stop_tick`, `(T, D)` timestamps): `:diasca`, `:parallel`, `:rust`

The corrected gap list:

| Theorem | Engines | Status |
|---|---|---|
| T1 within-time-group | `:engine` ↔ `:ets` | **Green** (week 1) — 30 trials, 1.5s, strict equality on M/M/c scenarios |
| T2' DSL equivalence | `:engine` ↔ `:ets` ↔ `:diasca` | **Green** (week 2) — Barbershop and SplitCombine DSL models, 30 trials each, 3.2s. Strict for engine↔ets, statistical for engine↔diasca with tunable per-property float tolerance. **`:parallel` and `:rust` reported as bugs (paper §5 findings #2 and #3) rather than equivalence claims.** |
| T2 within-tick-group | `:diasca` ↔ `:parallel` ↔ `:rust` | **Replaced by T2'.** Reconnaissance revealed the original framing was unworkable: the three tick engines have empty entity-protocol intersection. `:parallel` does not run DSL models without architectural changes (bug #2). `:rust` only accepts step-list input and silently no-ops on entity invocation (bug #3). The DSL emerged as the universal abstraction for the achievable subset, captured by T2'. |
| T3 cross-group bridge | T1/T2' integration | **Optional polish (week 3).** The DSL `run/1` already dispatches across modes; the equivalence relation already distinguishes strict from statistical. Whether T3 is a separate section vs. a paragraph in T2' is a prose decision, not technical. |

T2' is the achievable, defensible version of the killer angle: **the DSL is the universal abstraction**, and PropEr-driven equivalence verifies that DSL-compiled scenarios produce statistically equivalent observables across the engines that support them. The `:parallel` and `:rust` bug findings make the paper *stronger*, not weaker — they demonstrate that PropEr-driven cross-engine probing surfaces production bugs that 1100+ existing tests missed.

Subtleties (now confirmed by experiment, not speculation):
- **Numerical tolerance**: needed for T3 (cross-group), unnecessary for T1 and T2 (deterministic within group).
- **Simultaneous-event reordering**: required for T2. The `:parallel` engine partitions events at `(T, D)` across workers and may execute them in non-deterministic order within the diasca. The Tick-Diasca formalism (T, D+1) is exactly the right vocabulary: events at the same `(T, D)` are causally independent and may be reordered.
- **Scenario representability**: `:rust` only accepts DSL-style step lists (`[{:seize, 0}, {:hold, ...}, {:release, 0}, :depart]`), not arbitrary `Sim.Entity` modules. The normalized scenario representation must be the intersection of what all three tick-group engines accept. This *constrains* the generator (good — keeps scope tight) but does not reduce its value (the constrained subset still covers all 14 DSL verbs in some combination).

**2. A DSL model generator for PropEr.**
Currently the property tests use named fixture models (Barbershop, NoRework, etc.). For the inter-engine equivalence claim to be strong, we need a generator that produces *random valid DSL programs*: random topology of resources, random sequences of seize/hold/release/decide/route/batch/split/combine verbs, random distributions, random capacities. PropEr generators that produce well-formed nested data structures are well-documented; the work is mostly mechanical given the existing DSL grammar.

Estimated effort: 1.5 weeks (one for the generator, half for tuning + shrinking).

**3. Empirical results table for §6.**
Run the inter-engine equivalence suite. Report number of trials, number of divergences found (hopefully zero, or small + explainable), shrinking time, and any edge cases that need special handling. If we find a real divergence between (say) the centralized engine and the Rust NIF, that becomes a second bug-find story to add to §5.

### Important but not critical

**4. proper_statem model for the DSL compiler.**
A fourth `proper_statem` model that generates random DSL programs (overlap with #2) and asserts the compiled output behaves identically to a hand-written entity equivalent. This would round out the testing trinity into a quartet (compiler / engine / resource / preemptive) and let us claim "we tested every layer of sim_ex with PropEr." Lower priority because the inter-engine equivalence test partially subsumes this.

**5. Reproducibility appendix.**
Hardware spec, OTP version, seed values, exact command lines. Not novel but reviewers will look for it.

### Nice-to-have

**6. A schedule_event injection model.**
Listed in TODO.md. Generates events targeting non-existent entities to test orphan event handling. Would add ~0.25 page to §4. Skip if time-constrained.

**7. Circular seize / deadlock detection model.**
Also from TODO.md. Two resources with cross-dependency. Tests whether the engine detects or survives deadlock. Substantial work; defer to future.

---

## Five-week plan to May 14

| Week | Dates | Focus | Deliverable |
|------|-------|-------|-------------|
| 1 | Apr 8-14 | **Done in one session.** Baseline test runs locked in. T1 (within-time-group) test green. Engine taxonomy discovered and documented. Outline restructured into three theorems. | `inter_engine_equivalence_test.exs` skeleton + smoke test + T1 property green. Paper outline §6 reflects T1/T2/T3 split. **Statham baseline: 700 sequences, 1.5s, 0 failures. Property test baseline: 8 properties, 102.3s, 0 failures.** |
| 2 | Apr 8-9 | **Done in one session.** T2 reframed and implemented after empirical reconnaissance. Two new bug findings captured. Failed-fix story (parallel bridge clause infinite loop) recorded. | T2' DSL equivalence property green for Barbershop and SplitCombine across `:engine`, `:ets`, `:diasca`. 30 trials per property × 2 properties × 3 engines = **180 simulation runs in 3.2 seconds, 0 failures.** Bug findings #2 (`:parallel` crash) and #3 (`:rust` silent zero-events) captured as test assertions. |
| 3 | Apr 22-28 | T3 implementation + figures | T3 cross-group bridge with statistical-bound equivalence. Architecture figure (5 engines, time/tick groups). Testing taxonomy figure (clipboard/auditor/saboteur). §3, §4, §5 prose. |
| 4 | Apr 29-May 5 | Performance section + related work | §7, §8. Re-run benchmarks for fresh numbers (PHOLD, SimPy comparison). Write related work — Sim-Diasca, ROSS, ErlangTW, Quviq, Hughes Erlang QuickCheck papers. |
| 5 | May 6-13 | Polishing and submission | Full read-through, abstract trim to 200 words, figure cleanup, references audit. Internal review by trusted reader. Format check against ACM acmart. Submit by May 14. |

**Week 1 ahead of schedule.** The original plan budgeted week 1 for "spec lock + generator skeleton." We finished spec lock, generator skeleton, the T1 property, AND discovered the engine taxonomy that restructured §6. Net effect: week 2 starts with a working test scaffold, a clear technical target (T2), and one published anecdote (the shrunk counter-example).

Buffer: weeks 2 and 4 have ~1 day of slack each. Lonely Planet/Arbiter interviews and Wayne State teaching commitments take priority over week-1 outline work but should not block weeks 2-5.

---

## Open decisions

1. **Single-author or multi-author?** Igor is the author of sim_ex, eXMC, smc_ex, ex_stochtree, and the testing infrastructure. No co-authors needed for the technical contribution. If a co-author is desirable for credibility (e.g., a Wayne State faculty member), it must be settled by week 2 because the byline affects the abstract framing.

2. **Anonymous vs non-anonymous review.** The Erlang Workshop CFP needs to be checked. Many ACM SIGPLAN workshops are double-blind; some are not. This affects how we cite sim_ex in the body (anonymous: "an open-source library available on request"; non-anonymous: "github.com/borodark/sim_ex").

3. **eXMC integration framing.** The README pitches sim_ex as part of "Les Quatre Probabileurs" with eXMC, smc_ex, and stochtree_ex. For this paper, the eXMC integration is mentioned in §8 as future work — we do NOT make Bayesian input modeling a contribution because that would dilute the verification story. Confirm this scope discipline.

4. **Page count: 8 vs 12.** Workshop papers can be either. 10 is a comfortable middle. If §6 results are richer than expected (multiple bug-finds across engines), bump to 12. If the equivalence test reveals nothing interesting, stay at 8.

5. **Title decision.** Working title is long. Final options:
   - *"sim_ex: Verifying a Concurrent DES Library with PropEr"*
   - *"The Auditor and the Saboteur: Stateful Property Testing of a Multi-Engine Discrete Event Simulator on the BEAM"*
   - *"Inter-Engine Equivalence: PropEr-Driven Verification of a Multi-Backend Discrete Event Simulator"*

   Recommend: "sim_ex: Inter-Engine Equivalence and Stateful Property Testing of a BEAM Discrete Event Simulator" (specific, claimable, no cute subtitle).

---

## Notes for the writing process

- Cite **Sim-Diasca** (Olivier Boudeville, EDF, 2010) as the prior art that established BEAM as a credible DES platform. They did not publish a verification methodology paper; we are filling that gap.
- Cite **John Hughes** Erlang QuickCheck papers (Quviq) as the methodological ancestor. The Volvo / Ericsson case studies are the canonical examples of `proper_statem`-style stateful testing in Erlang industrial practice. We are continuing that lineage in a new domain.
- Cite **Maria Christakis et al.** on property-based testing for concurrent systems if any of their work on shrinking heuristics is relevant.
- Cite **Hennessy & Patterson** style for the architecture description discipline (one figure per architectural commitment, no hand-waving).
- The "clipboard / auditor / saboteur" framing is rhetorically strong — keep it. Reviewers will remember the metaphor and it's specific enough to be a genuine taxonomy, not pure marketing.
- The blog posts at dataalienist.com/blog-statham.html and blog-simpy-race.html exist and contain prior public framing of this work. They are NOT submission-quality but their content is reusable. Cite them if non-anonymous review allows.
- Avoid claiming novelty for things that already exist in the literature. "First stateful PBT verification of a DES engine" is a defensible claim only if we can cite a thorough enough lit review to back it up. The lit review work belongs to week 4.
