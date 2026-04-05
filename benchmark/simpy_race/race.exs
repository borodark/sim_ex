# sim_ex vs SimPy — Head-to-Head Race
#
# Same models, same parameters, same seeds where possible.
# Run SimPy first (sequential), then sim_ex (sequential).
# Each gets full CPU. Fair fight.
#
# Usage:
#   # 1. Run Python benchmarks
#   python benchmark/simpy_race/barbershop.py
#   python benchmark/simpy_race/job_shop.py
#   python benchmark/simpy_race/rework.py
#   python benchmark/simpy_race/batch_reps.py
#
#   # 2. Run Elixir benchmarks
#   mix run benchmark/simpy_race/race.exs

IO.puts("")
IO.puts("  sim_ex Race Results")
IO.puts("  " <> String.duplicate("─", 56))
IO.puts("  Machine: #{:erlang.system_info(:system_architecture)}")
IO.puts("  Cores: #{System.schedulers_online()}")
IO.puts("")

# ── 1. Barbershop M/M/1 ──

IO.puts("  ── Barbershop M/M/1 (interarrival=18, service=16) ──")

defmodule Race.Barber do
  use Sim.DSL
  model :barbershop do
    resource(:barber, capacity: 1)
    process :customer do
      arrive(every: exponential(18.0))
      seize(:barber)
      hold(exponential(16.0))
      release(:barber)
      depart
    end
  end
end

for stop <- [10_000, 50_000, 200_000] do
  # Elixir Engine
  t0 = System.monotonic_time(:microsecond)
  {:ok, re} = Race.Barber.run(stop_time: stop * 1.0, seed: 42)
  elixir_us = System.monotonic_time(:microsecond) - t0

  # Rust NIF
  steps = [{:seize, 0}, {:hold, {:exponential, 16.0}}, {:release, 0}, :depart]
  t0 = System.monotonic_time(:microsecond)
  {:ok, rr} = Sim.run(mode: :rust, resources: [%{capacity: 1}],
    processes: [%{steps: steps, arrival_mean: 18.0}],
    stop_tick: stop, seed: 42, batch_size: 1)
  rust_us = System.monotonic_time(:microsecond) - t0

  IO.puts("  stop=#{String.pad_trailing("#{stop}", 8)}" <>
    "  Elixir: #{String.pad_trailing("#{div(elixir_us, 1000)}ms", 8)}" <>
    "  Rust: #{String.pad_trailing("#{div(rust_us, 1000)}ms", 8)}" <>
    "  served=#{re.stats[:customer].completed}")
end

IO.puts("")

# ── 2. Job Shop (5 stages) ──

IO.puts("  ── Job Shop (5 stages × capacity 2) ──")

defmodule Race.JobShop do
  use Sim.DSL
  model :job_shop do
    resource(:s0, capacity: 2)
    resource(:s1, capacity: 2)
    resource(:s2, capacity: 2)
    resource(:s3, capacity: 2)
    resource(:s4, capacity: 2)
    process :part do
      arrive(every: exponential(4.0))
      seize(:s0); hold(exponential(8.0)); release(:s0)
      seize(:s1); hold(exponential(6.0)); release(:s1)
      seize(:s2); hold(exponential(10.0)); release(:s2)
      seize(:s3); hold(exponential(5.0)); release(:s3)
      seize(:s4); hold(exponential(7.0)); release(:s4)
      depart
    end
  end
end

for stop <- [10_000, 50_000, 200_000] do
  t0 = System.monotonic_time(:microsecond)
  {:ok, r} = Race.JobShop.run(stop_time: stop * 1.0, seed: 42)
  us = System.monotonic_time(:microsecond) - t0

  IO.puts("  stop=#{String.pad_trailing("#{stop}", 8)}" <>
    "  #{div(us, 1000)}ms  completed=#{r.stats[:part].completed}")
end

IO.puts("")

# ── 3. Rework Loop ──

IO.puts("  ── Rework Loop (15% rework probability) ──")

defmodule Race.Rework do
  use Sim.DSL
  model :rework do
    resource(:machine, capacity: 3)
    resource(:rework_station, capacity: 1)
    process :part do
      arrive(every: exponential(4.0))
      seize(:machine)
      hold(exponential(5.0))
      release(:machine)
      decide(0.15, :rework_loop)
      depart
      label(:rework_loop)
      seize(:rework_station)
      hold(exponential(8.0))
      release(:rework_station)
      depart
    end
  end
end

for stop <- [10_000, 50_000, 200_000] do
  t0 = System.monotonic_time(:microsecond)
  {:ok, r} = Race.Rework.run(stop_time: stop * 1.0, seed: 42)
  us = System.monotonic_time(:microsecond) - t0
  rework_pct = Float.round(r.stats[:rework_station].grants / max(r.stats[:machine].grants, 1) * 100, 1)

  IO.puts("  stop=#{String.pad_trailing("#{stop}", 8)}" <>
    "  #{div(us, 1000)}ms  completed=#{r.stats[:part].completed}" <>
    "  rework=#{rework_pct}%")
end

IO.puts("")

# ── 4. Batch Replications ──

IO.puts("  ── Batch Replications (barbershop, stop=10K) ──")

steps = [{:seize, 0}, {:hold, {:exponential, 16.0}}, {:release, 0}, :depart]

for n_reps <- [10, 100, 1000] do
  t0 = System.monotonic_time(:microsecond)

  results =
    for seed <- 1..n_reps do
      {:ok, r} = Sim.run(mode: :rust, resources: [%{capacity: 1}],
        processes: [%{steps: steps, arrival_mean: 18.0}],
        stop_tick: 10_000, seed: seed, batch_size: 1)
      r.stats[:process_0].completed
    end

  us = System.monotonic_time(:microsecond) - t0
  mean_served = Enum.sum(results) / length(results)
  per_rep_ms = Float.round(us / n_reps / 1000, 1)

  IO.puts("  #{String.pad_trailing("#{n_reps} reps", 10)}" <>
    "  #{div(us, 1000)}ms  per_rep=#{per_rep_ms}ms" <>
    "  mean_served=#{Float.round(mean_served, 0)}")
end

IO.puts("")
IO.puts("  " <> String.duplicate("═", 56))
IO.puts("  Paste SimPy results alongside for comparison.")
IO.puts("  Fair race: sequential execution, each gets full CPU.")
