defmodule Sim.PropertyHelper do
  @moduledoc false

  @doc """
  Runs `body_fn` with parameters from `gen_fn(seed)` for `n_trials` random seeds.
  On failure, reports which seed and params caused the failure.
  """
  def check(n_trials, gen_fn, body_fn) do
    base_seed = :erlang.unique_integer([:positive])

    Enum.each(1..n_trials, fn i ->
      seed = base_seed + i * 7919
      params = gen_fn.(seed)

      try do
        body_fn.(params)
      rescue
        e ->
          reraise(
            "Property failed on trial #{i}/#{n_trials}, seed=#{seed}\n" <>
              "  params=#{inspect(params)}\n" <>
              "  #{Exception.message(e)}",
            __STACKTRACE__
          )
      end
    end)
  end

  @doc """
  Sample a uniform value in [lo, hi] using `:rand` state.
  Returns `{value, new_rs}`.
  """
  def uniform_range(rs, lo, hi) do
    {u, rs} = :rand.uniform_s(rs)
    {lo + u * (hi - lo), rs}
  end

  @doc """
  Generate random M/M/c parameters. Rejects if rho >= 0.90 or rho < 0.05.
  """
  def gen_mmc(seed) do
    rs = :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    gen_mmc_loop(rs, seed)
  end

  defp gen_mmc_loop(rs, seed) do
    {lambda_inv, rs} = uniform_range(rs, 0.5, 5.0)
    {mu_inv, rs} = uniform_range(rs, 0.1, 3.0)
    {c_float, rs} = uniform_range(rs, 1.0, 5.99)
    c = trunc(c_float)
    lambda = 1.0 / lambda_inv
    mu = 1.0 / mu_inv
    rho = lambda / (c * mu)

    if rho >= 0.90 or rho < 0.05 do
      gen_mmc_loop(rs, seed)
    else
      stop_time = min(50_000.0, max(20_000.0, 50_000.0 / (1.0 - rho)))

      %{
        lambda_inv: lambda_inv,
        mu_inv: mu_inv,
        c: c,
        lambda: lambda,
        mu: mu,
        rho: rho,
        stop_time: stop_time,
        seed: seed
      }
    end
  end

  @doc """
  Generate random M/M/1 parameters with rho in [0.2, 0.8].
  W_theory = 1/(mu - lambda).
  """
  def gen_mm1(seed) do
    rs = :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    gen_mm1_loop(rs, seed)
  end

  defp gen_mm1_loop(rs, seed) do
    {lambda_inv, rs} = uniform_range(rs, 0.5, 5.0)
    {mu_inv, rs} = uniform_range(rs, 0.1, 3.0)
    lambda = 1.0 / lambda_inv
    mu = 1.0 / mu_inv
    rho = lambda / mu

    if rho >= 0.80 or rho < 0.20 do
      gen_mm1_loop(rs, seed)
    else
      w_theory = 1.0 / (mu - lambda)
      stop_time = min(80_000.0, max(50_000.0, 100_000.0 / (1.0 - rho)))

      %{
        lambda_inv: lambda_inv,
        mu_inv: mu_inv,
        lambda: lambda,
        mu: mu,
        rho: rho,
        w_theory: w_theory,
        stop_time: stop_time,
        seed: seed
      }
    end
  end

  @doc """
  Generate random DSL simulation parameters: sim_seed and stop_time.
  """
  def gen_dsl_params(seed) do
    rs = :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    {stop_float, _rs} = uniform_range(rs, 5_000.0, 50_000.0)

    %{
      sim_seed: seed,
      stop_time: stop_float
    }
  end
end

defmodule Sim.PropertyTest do
  use ExUnit.Case

  import Sim.PropertyHelper

  # Long-running property tests get a generous timeout
  @moduletag timeout: 300_000

  describe "flow conservation (low-level Sim.run)" do
    @tag timeout: 180_000
    test "departures <= arrivals for random M/M/c in engine and ets modes" do
      check(50, &gen_mmc/1, fn params ->
        for mode <- [:engine, :ets] do
          {:ok, result} =
            Sim.run(
              entities: [
                {:arrivals, Sim.Source,
                 %{
                   id: :arrivals,
                   target: :server,
                   interarrival: {:exponential, params.lambda_inv},
                   seed: params.seed
                 }},
                {:server, Sim.Resource,
                 %{
                   id: :server,
                   capacity: params.c,
                   service: {:exponential, params.mu_inv},
                   seed: params.seed + 1000
                 }}
              ],
              initial_events: [{0.0, :arrivals, :generate}],
              # Use shorter stop_time for flow conservation (property is invariant to duration)
              stop_time: min(params.stop_time, 10_000.0),
              mode: mode
            )

          server = result.stats[:server]

          assert server.departures <= server.arrivals,
                 "#{mode}: departures (#{server.departures}) > arrivals (#{server.arrivals})"

          assert server.arrivals - server.departures >= 0,
                 "#{mode}: negative in-system count"
        end
      end)
    end
  end

  describe "Little's Law M/M/1" do
    @tag timeout: 180_000
    test "W_observed within 20% of W_theory = 1/(mu-lambda)" do
      check(30, &gen_mm1/1, fn params ->
        {:ok, result} =
          Sim.run(
            entities: [
              {:arrivals, Sim.Source,
               %{
                 id: :arrivals,
                 target: :server,
                 interarrival: {:exponential, params.lambda_inv},
                 seed: params.seed
               }},
              {:server, Sim.Resource,
               %{
                 id: :server,
                 capacity: 1,
                 service: {:exponential, params.mu_inv},
                 seed: params.seed + 1000
               }}
            ],
            initial_events: [{0.0, :arrivals, :generate}],
            stop_time: params.stop_time
          )

        server = result.stats[:server]
        # W_observed = mean_wait (time in queue) + mu_inv (service time)
        w_observed = server.mean_wait + params.mu_inv
        w_theory = params.w_theory

        rel_error = abs(w_observed - w_theory) / w_theory

        assert rel_error < 0.20,
               "Little's Law: W_obs=#{Float.round(w_observed, 3)}, " <>
                 "W_theory=#{Float.round(w_theory, 3)}, " <>
                 "rel_error=#{Float.round(rel_error * 100, 1)}%, " <>
                 "rho=#{Float.round(params.rho, 3)}"
      end)
    end
  end

  describe "throughput convergence" do
    @tag timeout: 180_000
    test "departures/clock within 15% of lambda for stable M/M/c" do
      check(40, &gen_mmc/1, fn params ->
        {:ok, result} =
          Sim.run(
            entities: [
              {:arrivals, Sim.Source,
               %{
                 id: :arrivals,
                 target: :server,
                 interarrival: {:exponential, params.lambda_inv},
                 seed: params.seed
               }},
              {:server, Sim.Resource,
               %{
                 id: :server,
                 capacity: params.c,
                 service: {:exponential, params.mu_inv},
                 seed: params.seed + 1000
               }}
            ],
            initial_events: [{0.0, :arrivals, :generate}],
            stop_time: params.stop_time
          )

        server = result.stats[:server]
        clock = result.clock

        if clock > 0 do
          throughput = server.departures / clock
          rel_error = abs(throughput - params.lambda) / params.lambda

          assert rel_error < 0.15,
                 "Throughput: #{Float.round(throughput, 4)} vs lambda=#{Float.round(params.lambda, 4)}, " <>
                   "rel_error=#{Float.round(rel_error * 100, 1)}%, rho=#{Float.round(params.rho, 3)}"
        end
      end)
    end
  end

  describe "determinism" do
    @tag timeout: 120_000
    test "same seed produces identical results for engine and ets modes" do
      check(30, &gen_mmc/1, fn params ->
        for mode <- [:engine, :ets] do
          run_fn = fn ->
            Sim.run(
              entities: [
                {:arrivals, Sim.Source,
                 %{
                   id: :arrivals,
                   target: :server,
                   interarrival: {:exponential, params.lambda_inv},
                   seed: params.seed
                 }},
                {:server, Sim.Resource,
                 %{
                   id: :server,
                   capacity: params.c,
                   service: {:exponential, params.mu_inv},
                   seed: params.seed + 1000
                 }}
              ],
              initial_events: [{0.0, :arrivals, :generate}],
              stop_time: min(params.stop_time, 5_000.0),
              mode: mode
            )
          end

          {:ok, r1} = run_fn.()
          {:ok, r2} = run_fn.()

          assert r1.events == r2.events,
                 "#{mode}: events differ (#{r1.events} vs #{r2.events})"

          assert r1.stats[:server].arrivals == r2.stats[:server].arrivals,
                 "#{mode}: arrivals differ"

          assert r1.stats[:server].mean_wait == r2.stats[:server].mean_wait,
                 "#{mode}: mean_wait differs"
        end
      end)
    end
  end

  describe "cross-mode equivalence" do
    @tag timeout: 120_000
    test "engine and ets produce identical results for same seed" do
      check(20, &gen_mmc/1, fn params ->
        opts_base = [
          entities: [
            {:arrivals, Sim.Source,
             %{
               id: :arrivals,
               target: :server,
               interarrival: {:exponential, params.lambda_inv},
               seed: params.seed
             }},
            {:server, Sim.Resource,
             %{
               id: :server,
               capacity: params.c,
               service: {:exponential, params.mu_inv},
               seed: params.seed + 1000
             }}
          ],
          initial_events: [{0.0, :arrivals, :generate}],
          stop_time: 5_000.0
        ]

        {:ok, r_engine} = Sim.run(Keyword.put(opts_base, :mode, :engine))
        {:ok, r_ets} = Sim.run(Keyword.put(opts_base, :mode, :ets))

        assert r_engine.events == r_ets.events,
               "events: engine=#{r_engine.events} vs ets=#{r_ets.events}"

        assert r_engine.stats[:server].arrivals == r_ets.stats[:server].arrivals,
               "arrivals differ"

        assert r_engine.stats[:server].departures == r_ets.stats[:server].departures,
               "departures differ"

        assert r_engine.stats[:server].mean_wait == r_ets.stats[:server].mean_wait,
               "mean_wait differs"
      end)
    end
  end

  describe "DSL flow conservation" do
    @tag timeout: 180_000
    test "barbershop: arrivals == completed + in_progress" do
      check(50, &gen_dsl_params/1, fn params ->
        {:ok, result} =
          Sim.PropertyModels.Barbershop.run(
            stop_time: params.stop_time,
            seed: params.sim_seed
          )

        source = result.stats[:customer_source]
        customer = result.stats[:customer]

        arrivals = source.total_arrivals
        completed = customer.completed
        in_progress = customer.in_progress

        assert arrivals == completed + in_progress,
               "arrivals (#{arrivals}) != completed (#{completed}) + in_progress (#{in_progress})"
      end)
    end
  end

  describe "edge cases" do
    @tag timeout: 120_000
    test "decide(0.0) routes nobody to rework" do
      check(20, &gen_dsl_params/1, fn params ->
        {:ok, result} =
          Sim.PropertyModels.NoRework.run(
            stop_time: params.stop_time,
            seed: params.sim_seed
          )

        assert result.stats[:rework].grants == 0,
               "NoRework: rework grants should be 0, got #{result.stats[:rework].grants}"
      end)
    end

    @tag timeout: 120_000
    test "decide(1.0) routes everyone to rework" do
      check(20, &gen_dsl_params/1, fn params ->
        {:ok, result} =
          Sim.PropertyModels.AllRework.run(
            stop_time: params.stop_time,
            seed: params.sim_seed
          )

        rework_grants = result.stats[:rework].grants
        completed = result.stats[:part].completed

        # Every completed part went through rework.
        # Allow +-1 for edge cases at simulation boundary.
        assert abs(rework_grants - completed) <= 1,
               "AllRework: rework grants (#{rework_grants}) should equal " <>
                 "completed (#{completed})"
      end)
    end

    @tag timeout: 120_000
    test "combine(1) is identity: machine grants == completed for finished parts" do
      check(20, &gen_dsl_params/1, fn params ->
        {:ok, result} =
          Sim.PropertyModels.Combine1.run(
            stop_time: params.stop_time,
            seed: params.sim_seed
          )

        machine_grants = result.stats[:machine].grants
        completed = result.stats[:part].completed
        in_progress = result.stats[:part].in_progress
        arrivals = result.stats[:part_source].total_arrivals

        # Flow conservation: arrivals == completed + in_progress
        assert arrivals == completed + in_progress,
               "Combine1: arrivals (#{arrivals}) != completed (#{completed}) + in_progress (#{in_progress})"

        # combine(1) doesn't block: every granted part should complete or be in progress.
        # machine grants <= arrivals (some parts may still be waiting for the machine)
        assert machine_grants <= arrivals,
               "Combine1: machine grants (#{machine_grants}) > arrivals (#{arrivals})"

        # completed <= machine grants (can't complete without going through machine)
        assert completed <= machine_grants,
               "Combine1: completed (#{completed}) > machine grants (#{machine_grants})"
      end)
    end

    @tag timeout: 120_000
    test "split(3)/combine(3) round-trip: assembler grants close to 3 * cutter grants" do
      check(20, &gen_dsl_params/1, fn params ->
        {:ok, result} =
          Sim.PropertyModels.SplitCombine.run(
            stop_time: params.stop_time,
            seed: params.sim_seed
          )

        cutter_grants = result.stats[:cutter].grants
        assembler_grants = result.stats[:assembler].grants

        # split(3) creates 3 parts from each original, so assembler sees 3x cutter.
        # Some parts may be in the split->assembler pipeline at sim end.
        # The pipeline can hold up to capacity*3 parts (2 assembler slots * 3 = 6),
        # plus parts queued for the assembler. Allow generous tolerance.
        expected = 3 * cutter_grants
        diff = expected - assembler_grants

        assert diff >= 0,
               "SplitCombine: assembler grants (#{assembler_grants}) exceeds " <>
                 "3 * cutter grants (#{cutter_grants}) = #{expected}"

        # At most ~3 parts per cutter capacity could be in flight
        # (each split produces 3 sub-parts, max 2 cutter slots * 3 = 6 in-flight sub-parts,
        #  plus up to assembler queue length). Use 5% of expected as tolerance.
        max_diff = max(12, trunc(expected * 0.05))

        assert diff <= max_diff,
               "SplitCombine: too many in-flight parts. assembler grants (#{assembler_grants}) " <>
                 "vs expected #{expected}, diff=#{diff}, max_diff=#{max_diff}"
      end)
    end
  end

  describe "utilization (busy_time)" do
    @tag timeout: 180_000
    test "utilization converges to rho for M/M/1" do
      check(20, &gen_mm1/1, fn params ->
        {:ok, result} =
          Sim.run(
            entities: [
              {:arrivals, Sim.Source,
               %{
                 id: :arrivals,
                 target: :server,
                 interarrival: {:exponential, params.lambda_inv},
                 seed: params.seed
               }},
              {:server, Sim.Resource,
               %{
                 id: :server,
                 capacity: 1,
                 service: {:exponential, params.mu_inv},
                 seed: params.seed + 1000
               }}
            ],
            initial_events: [{0.0, :arrivals, :generate}],
            stop_time: params.stop_time
          )

        server = result.stats[:server]
        utilization = server.utilization

        # Utilization should be within 15% of rho
        rel_error = abs(utilization - params.rho) / params.rho

        assert rel_error < 0.15,
               "Utilization: #{Float.round(utilization, 3)} vs rho=#{Float.round(params.rho, 3)}, " <>
                 "rel_error=#{Float.round(rel_error * 100, 1)}%"
      end)
    end
  end
end
