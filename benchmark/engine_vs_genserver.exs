# Engine vs GenServer mode — PHOLD benchmark
#
# Usage: mix run benchmark/engine_vs_genserver.exs

IO.puts("Engine vs GenServer — PHOLD A/B Test")
IO.puts("=" |> String.duplicate(60))
IO.puts("Cores: #{System.schedulers_online()}")
IO.puts("")

configs = [
  {100,    16, 0.25, 10.0},
  {1_000,  16, 0.25, 10.0},
  {10_000, 16, 0.25, 10.0},
  {100,    16, 0.25, 100.0},
  {1_000,  16, 0.25, 100.0},
  {10_000, 16, 0.25, 100.0},
]

header =
  String.pad_trailing("LPs", 8) <>
  String.pad_trailing("Stop", 6) <>
  String.pad_trailing("Events", 12) <>
  String.pad_trailing("Engine(ms)", 12) <>
  String.pad_trailing("GS(ms)", 12) <>
  String.pad_trailing("Eng E/s", 14) <>
  String.pad_trailing("GS E/s", 14) <>
  "Speedup"

IO.puts(header)
IO.puts("-" |> String.duplicate(80))

for {num_lps, epl, rf, stop} <- configs do
  sim_opts = fn mode ->
    entities =
      for lp <- 0..(num_lps - 1) do
        {lp, Sim.PHOLD, %{
          id: lp,
          num_lps: num_lps,
          remote_fraction: rf,
          mean_delay: 1.0,
          seed: lp
        }}
      end

    initial_events =
      for lp <- 0..(num_lps - 1), _ <- 1..epl do
        {0.0, lp, :ping}
      end

    [
      entities: entities,
      initial_events: initial_events,
      stop_time: stop,
      mode: mode
    ]
  end

  # Engine mode
  t0 = System.monotonic_time(:microsecond)
  {:ok, r_eng} = Sim.run(sim_opts.(:engine))
  engine_us = System.monotonic_time(:microsecond) - t0
  engine_ms = div(engine_us, 1000)

  # GenServer mode
  t0 = System.monotonic_time(:microsecond)
  {:ok, r_gs} = Sim.run(sim_opts.(:genserver))
  gs_us = System.monotonic_time(:microsecond) - t0
  gs_ms = div(gs_us, 1000)

  eng_eps = if engine_ms > 0, do: trunc(r_eng.events / (engine_ms / 1000.0)), else: 0
  gs_eps = if gs_ms > 0, do: trunc(r_gs.events / (gs_ms / 1000.0)), else: 0
  speedup = if engine_ms > 0, do: Float.round(gs_ms / engine_ms, 1), else: 0.0

  IO.puts(
    String.pad_trailing("#{num_lps}", 8) <>
    String.pad_trailing("#{stop}", 6) <>
    String.pad_trailing("#{r_eng.events}", 12) <>
    String.pad_trailing("#{engine_ms}", 12) <>
    String.pad_trailing("#{gs_ms}", 12) <>
    String.pad_trailing("#{eng_eps}", 14) <>
    String.pad_trailing("#{gs_eps}", 14) <>
    "#{speedup}x"
  )
end
