# PHOLD Benchmark — Standard DES performance test
#
# Usage: mix run benchmark/phold_bench.exs
#
# Sweeps LP count and remote fraction to characterize throughput.

IO.puts("PHOLD Benchmark — sim_ex on BEAM")
IO.puts("=" |> String.duplicate(60))
IO.puts("Cores: #{System.schedulers_online()}")
IO.puts("")

configs = [
  # {num_lps, events_per_lp, remote_fraction, stop_time}
  {100,     16, 0.10, 100.0},
  {1_000,   16, 0.10, 100.0},
  {10_000,  16, 0.10, 100.0},
  {100,     16, 0.25, 100.0},
  {1_000,   16, 0.25, 100.0},
  {10_000,  16, 0.25, 100.0},
  {100,     16, 0.50, 100.0},
  {1_000,   16, 0.50, 100.0},
  {10_000,  16, 0.50, 100.0},
]

IO.puts(String.pad_trailing("LPs", 10) <>
  String.pad_trailing("E/LP", 6) <>
  String.pad_trailing("Remote", 10) <>
  String.pad_trailing("Events", 12) <>
  String.pad_trailing("Wall(ms)", 12) <>
  String.pad_trailing("Events/s", 15))
IO.puts("-" |> String.duplicate(65))

for {num_lps, epl, rf, stop} <- configs do
  result = Sim.PHOLD.run(
    num_lps: num_lps,
    events_per_lp: epl,
    remote_fraction: rf,
    stop_time: stop
  )

  eps = Float.round(result.events_per_second, 0) |> trunc()

  IO.puts(
    String.pad_trailing("#{num_lps}", 10) <>
    String.pad_trailing("#{epl}", 6) <>
    String.pad_trailing("#{rf}", 10) <>
    String.pad_trailing("#{result.total_events}", 12) <>
    String.pad_trailing("#{result.wall_time_ms}", 12) <>
    String.pad_trailing("#{eps}", 15)
  )
end

IO.puts("")
IO.puts("Note: This is single-node, inline mode (no process-per-entity).")
IO.puts("ROSS achieves 504B events/s on 1.9M cores. We're measuring single-BEAM throughput.")
