# DSL Complexity Benchmark
#
# How does DSL verb complexity affect throughput?
# From barbershop (5 verbs) to electronics fab (split+decide+combine+batch).
#
# "The question is not whether the DSL is fast enough.
#  The question is whether the abstraction costs anything."

IO.puts("")
IO.puts("  DSL Complexity Benchmark")
IO.puts("  " <> String.duplicate("─", 56))
IO.puts("  Same engine. Same runtime. More verbs. What happens?")
IO.puts("")

# ── Model 1: Barbershop (5 verbs) ──────────────────────────

defmodule Bench.Barbershop do
  use Sim.DSL
  model :barbershop do
    resource(:barber, capacity: 1)
    process :customer do
      arrive(every: exponential(4.0))
      seize(:barber)
      hold(exponential(3.0))
      release(:barber)
      depart
    end
  end
end

# ── Model 2: Job Shop (8 verbs, 2 resources) ───────────────

defmodule Bench.JobShop do
  use Sim.DSL
  model :job_shop do
    resource(:drill, capacity: 2)
    resource(:lathe, capacity: 1)
    process :part do
      arrive(every: exponential(4.0))
      seize(:drill)
      hold(exponential(3.0))
      release(:drill)
      seize(:lathe)
      hold(exponential(4.0))
      release(:lathe)
      depart
    end
  end
end

# ── Model 3: Rework Line (decide + label) ──────────────────

defmodule Bench.ReworkLine do
  use Sim.DSL
  model :rework_line do
    resource(:machine, capacity: 3)
    resource(:rework, capacity: 1)
    process :part do
      arrive(every: exponential(4.0))
      seize(:machine)
      hold(exponential(3.0))
      release(:machine)
      decide(0.15, :rework_station)
      depart
      label(:rework_station)
      seize(:rework)
      hold(exponential(6.0))
      release(:rework)
      depart
    end
  end
end

# ── Model 4: Packaging (5 stages + route + schedule) ───────

defmodule Bench.Packaging do
  use Sim.DSL
  model :packaging do
    resource(:fill, capacity: 3)
    resource(:cap, capacity: 3)
    resource(:label_station, capacity: 3)
    resource(:inspect, schedule: [{0..4799, 3}, {4800..9599, 2}])
    resource(:box, capacity: 3)
    process :vial do
      arrive(schedule: [{0..4799, {:exponential, 3.0}}, {4800..9599, {:exponential, 5.0}}])
      seize(:fill)
      hold(exponential(5.0))
      release(:fill)
      route(exponential(0.5))
      seize(:cap)
      hold(exponential(3.5))
      release(:cap)
      route(exponential(0.3))
      seize(:label_station)
      hold(exponential(4.0))
      release(:label_station)
      route(exponential(0.3))
      seize(:inspect)
      hold(exponential(5.5))
      release(:inspect)
      route(exponential(0.3))
      seize(:box)
      hold(exponential(2.5))
      release(:box)
      depart
    end
  end
end

# ── Model 5: Electronics (split + decide + combine + batch) ─

defmodule Bench.Electronics do
  use Sim.DSL
  model :electronics do
    resource(:splitter, capacity: 1)
    resource(:solder, capacity: 8)
    resource(:aoi, capacity: 4)
    resource(:rework_solder, capacity: 2)
    resource(:final_tester, capacity: 2)
    process :pcb do
      arrive(every: exponential(4.0))
      seize(:splitter)
      hold(exponential(2.0))
      release(:splitter)
      split(4)
      seize(:solder)
      hold(exponential(3.0))
      release(:solder)
      seize(:aoi)
      hold(exponential(1.5))
      release(:aoi)
      decide(0.05, :rework_panel)
      combine(4)
      batch(10)
      seize(:final_tester)
      hold(exponential(5.0))
      release(:final_tester)
      depart
      label(:rework_panel)
      seize(:rework_solder)
      hold(exponential(6.0))
      release(:rework_solder)
      depart
    end
  end
end

# ── Model 6: Full Fab (everything at once) ──────────────────

defmodule Bench.FullFab do
  use Sim.DSL
  model :full_fab do
    resource(:etch, capacity: 4)
    resource(:deposit, capacity: 3)
    resource(:litho, capacity: 2)
    resource(:inspect_qc, schedule: [{0..4799, 3}, {4800..9599, 2}])
    resource(:rework_etch, capacity: 1)
    resource(:rework_dep, capacity: 1)
    resource(:final_test, capacity: 2)
    resource(:packer, capacity: 1)
    process :wafer do
      arrive(schedule: [{0..4799, {:exponential, 3.0}}, {4800..9599, {:exponential, 5.0}}])
      seize(:etch)
      hold(exponential(7.0))
      release(:etch)
      route(exponential(1.0))
      seize(:deposit)
      hold(exponential(5.0))
      release(:deposit)
      route(exponential(1.0))
      seize(:litho)
      hold(exponential(9.0))
      release(:litho)
      route(exponential(0.5))
      seize(:inspect_qc)
      hold(exponential(3.0))
      release(:inspect_qc)
      decide([{0.85, :passed}, {0.10, :rework_loop}, {0.05, :scrapped}])
      depart
      label(:passed)
      batch(6)
      seize(:final_test)
      hold(exponential(4.0))
      release(:final_test)
      seize(:packer)
      hold(exponential(2.0))
      release(:packer)
      depart
      label(:rework_loop)
      seize(:rework_etch)
      hold(exponential(10.0))
      release(:rework_etch)
      seize(:rework_dep)
      hold(exponential(8.0))
      release(:rework_dep)
      decide(0.5, :scrapped)
      seize(:final_test)
      hold(exponential(4.0))
      release(:final_test)
      depart
      label(:scrapped)
      depart
    end
  end
end

# ── Run benchmarks ──────────────────────────────────────────

models = [
  {"Barbershop",  fn -> Bench.Barbershop.run(stop_time: 50_000.0, seed: 42) end,
   "5 verbs, 1 resource"},
  {"Job Shop",    fn -> Bench.JobShop.run(stop_time: 50_000.0, seed: 42) end,
   "8 verbs, 2 resources"},
  {"Rework Line", fn -> Bench.ReworkLine.run(stop_time: 50_000.0, seed: 42) end,
   "decide + label + rework"},
  {"Packaging",   fn -> Bench.Packaging.run(stop_time: 50_000.0, seed: 42) end,
   "5 stages, route, schedule, non-stationary"},
  {"Electronics", fn -> Bench.Electronics.run(stop_time: 50_000.0, seed: 42) end,
   "split(4) + decide + combine(4) + batch(10)"},
  {"Full Fab",    fn -> Bench.FullFab.run(stop_time: 50_000.0, seed: 42) end,
   "8 resources, route, schedule, decide_multi, batch, rework"},
]

IO.puts(
  "  " <>
  String.pad_trailing("Model", 14) <>
  String.pad_trailing("Events", 10) <>
  String.pad_trailing("Wall(ms)", 10) <>
  String.pad_trailing("E/s", 12) <>
  String.pad_trailing("Parts", 8) <>
  "Description"
)
IO.puts("  " <> String.duplicate("─", 80))

results =
  for {name, run_fn, desc} <- models do
    :erlang.garbage_collect()
    t0 = System.monotonic_time(:microsecond)
    {:ok, r} = run_fn.()
    us = System.monotonic_time(:microsecond) - t0
    ms = div(us, 1000)
    eps = if us > 0, do: trunc(r.events / (us / 1_000_000)), else: 0

    # Find the process stats — first key matching a process
    proc_key = r.stats |> Map.keys() |> Enum.find(fn k ->
      is_atom(k) and not String.starts_with?(to_string(k), "resource") and
        Map.has_key?(r.stats[k] || %{}, :completed)
    end)
    completed = if proc_key, do: r.stats[proc_key].completed, else: 0

    IO.puts(
      "  " <>
      String.pad_trailing(name, 14) <>
      String.pad_trailing("#{r.events}", 10) <>
      String.pad_trailing("#{ms}", 10) <>
      String.pad_trailing("#{eps}", 12) <>
      String.pad_trailing("#{completed}", 8) <>
      desc
    )

    %{name: name, events: r.events, ms: ms, eps: eps, completed: completed}
  end

IO.puts("")

# ── Also test on Rust engine (simple models only) ──────────

IO.puts("  Rust Engine Comparison (barbershop-equivalent)")
IO.puts("  " <> String.duplicate("─", 56))

for stop <- [50_000, 500_000] do
  steps = [{:seize, 0}, {:hold, {:exponential, 3.0}}, {:release, 0}, :depart]
  t0 = System.monotonic_time(:microsecond)
  {:ok, r} = Sim.run(mode: :rust, resources: [%{capacity: 1}],
    processes: [%{steps: steps, arrival_mean: 4.0}],
    stop_tick: stop, seed: 42, batch_size: 1)
  us = System.monotonic_time(:microsecond) - t0
  eps = if us > 0, do: trunc(r.events / (us / 1_000_000)), else: 0
  IO.puts("  stop=#{String.pad_trailing("#{stop}", 8)} #{eps} E/s  (#{r.events} events, #{div(us, 1000)}ms)")
end

IO.puts("")

# ── Summary ─────────────────────────────────────────────────

fastest = Enum.max_by(results, & &1.eps)
slowest = Enum.min_by(results, & &1.eps)
ratio = Float.round(fastest.eps / max(slowest.eps, 1), 1)

IO.puts("  " <> String.duplicate("═", 56))
IO.puts("  Fastest: #{fastest.name} at #{fastest.eps} E/s")
IO.puts("  Slowest: #{slowest.name} at #{slowest.eps} E/s")
IO.puts("  Complexity tax: #{ratio}x between simplest and most complex")
IO.puts("")
IO.puts("  The abstraction costs #{ratio}x. The Bayesian posteriors are free.")
IO.puts("  The Rust engine is there when #{ratio}x matters.")
