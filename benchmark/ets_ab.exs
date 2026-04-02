# ETS Engine A/B Test — Map vs ETS entity storage
#
# The hypothesis: at 10K+ entities, ETS O(1) lookup beats Map O(log32 N).
# At <1K, Map may win (no ETS call overhead).

IO.puts("ETS Engine A/B — PHOLD")
IO.puts("=" |> String.duplicate(72))
IO.puts("Cores: #{System.schedulers_online()}")
IO.puts("")

configs = [
  {100, 100.0},
  {1_000, 100.0},
  {10_000, 100.0},
  {50_000, 50.0},
  {100_000, 20.0},
]

IO.puts(
  String.pad_trailing("LPs", 10) <>
  String.pad_trailing("Map E/s", 14) <>
  String.pad_trailing("ETS E/s", 14) <>
  String.pad_trailing("Speedup", 10) <>
  String.pad_trailing("Map(MB)", 10) <>
  "ETS(MB)"
)
IO.puts("-" |> String.duplicate(62))

for {num_lps, stop} <- configs do
  # Build shared config
  entities = for lp <- 0..(num_lps - 1) do
    {lp, Sim.PHOLD, %{id: lp, num_lps: num_lps, remote_fraction: 0.25,
      mean_delay: 1.0, seed: lp}}
  end

  initial = for lp <- 0..(num_lps - 1), _ <- 1..16, do: {0.0, lp, :ping}

  # Map engine
  :erlang.garbage_collect()
  mem_before = :erlang.memory(:total)
  t0 = System.monotonic_time(:microsecond)
  {:ok, r_map} = Sim.run(entities: entities, initial_events: initial,
    stop_time: stop, mode: :engine)
  map_us = System.monotonic_time(:microsecond) - t0
  map_mb = Float.round((:erlang.memory(:total) - mem_before) / 1_048_576, 1)

  # ETS engine
  :erlang.garbage_collect()
  mem_before = :erlang.memory(:total)
  t0 = System.monotonic_time(:microsecond)
  {:ok, r_ets} = Sim.run(entities: entities, initial_events: initial,
    stop_time: stop, mode: :ets)
  ets_us = System.monotonic_time(:microsecond) - t0
  ets_mb = Float.round((:erlang.memory(:total) - mem_before) / 1_048_576, 1)

  map_eps = if map_us > 0, do: trunc(r_map.events / (map_us / 1_000_000)), else: 0
  ets_eps = if ets_us > 0, do: trunc(r_ets.events / (ets_us / 1_000_000)), else: 0
  speedup = if map_eps > 0, do: Float.round(ets_eps / map_eps, 2), else: 0.0

  IO.puts(
    String.pad_trailing("#{num_lps}", 10) <>
    String.pad_trailing("#{map_eps}", 14) <>
    String.pad_trailing("#{ets_eps}", 14) <>
    String.pad_trailing("#{speedup}x", 10) <>
    String.pad_trailing("#{map_mb}", 10) <>
    "#{ets_mb}"
  )
end
