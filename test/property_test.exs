defmodule Sim.PropertyHelper do
  @moduledoc "Hand-rolled harness for stochastic properties where PropCheck shrinking chases Monte Carlo noise."

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

  def uniform_range(rs, lo, hi) do
    {u, rs} = :rand.uniform_s(rs)
    {lo + u * (hi - lo), rs}
  end

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

    if rho >= 0.70 or rho < 0.20 do
      gen_mm1_loop(rs, seed)
    else
      %{
        lambda_inv: lambda_inv,
        mu_inv: mu_inv,
        lambda: lambda,
        mu: mu,
        rho: rho,
        w_theory: 1.0 / (mu - lambda),
        stop_time: min(80_000.0, max(50_000.0, 100_000.0 / (1.0 - rho))),
        seed: seed
      }
    end
  end

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
      %{
        lambda_inv: lambda_inv,
        mu_inv: mu_inv,
        c: c,
        lambda: lambda,
        mu: mu,
        rho: rho,
        stop_time: min(50_000.0, max(20_000.0, 50_000.0 / (1.0 - rho))),
        seed: seed
      }
    end
  end

  def gen_dsl_params(seed) do
    rs = :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    {stop_float, _rs} = uniform_range(rs, 5_000.0, 50_000.0)
    %{sim_seed: seed, stop_time: stop_float}
  end
end

defmodule Sim.PropertyTest do
  use ExUnit.Case
  use PropCheck

  @moduletag timeout: 300_000

  # === PropCheck generators for exact (deterministic) properties ===

  defp mmc_gen do
    such_that(
      {lambda_inv, mu_inv, c_float, _seed} <-
        {float(0.5, 5.0), float(0.1, 3.0), float(1.0, 5.99), integer(100, 1_000_000)},
      when:
        (fn li, mi, cf ->
           c = trunc(cf)
           rho = mi / (c * li)
           rho >= 0.05 and rho < 0.90
         end).(lambda_inv, mu_inv, c_float)
    )
  end

  defp dsl_gen do
    {integer(100, 1_000_000), float(5_000.0, 50_000.0)}
  end

  defp run_mmc({lambda_inv, mu_inv, c_float, seed}, opts) do
    mode = opts[:mode] || :engine

    stop =
      opts[:stop_time] ||
        min(50_000.0, max(20_000.0, 50_000.0 / (1.0 - mu_inv / (trunc(c_float) * lambda_inv))))

    Sim.run(
      entities: [
        {:arrivals, Sim.Source,
         %{id: :arrivals, target: :server, interarrival: {:exponential, lambda_inv}, seed: seed}},
        {:server, Sim.Resource,
         %{
           id: :server,
           capacity: trunc(c_float),
           service: {:exponential, mu_inv},
           seed: seed + 1000
         }}
      ],
      initial_events: [{0.0, :arrivals, :generate}],
      stop_time: stop,
      mode: mode
    )
  end

  # ================================================================
  # EXACT PROPERTIES — PropCheck with shrinking
  # ================================================================

  describe "flow conservation (PropCheck)" do
    property "departures <= arrivals for random M/M/c", numtests: 50 do
      forall params <- mmc_gen() do
        Enum.all?([:engine, :ets], fn mode ->
          {:ok, result} = run_mmc(params, mode: mode, stop_time: 10_000.0)
          s = result.stats[:server]
          s.departures <= s.arrivals and s.arrivals - s.departures >= 0
        end)
      end
    end
  end

  describe "determinism (PropCheck)" do
    property "same seed produces identical results", numtests: 30 do
      forall params <- mmc_gen() do
        Enum.all?([:engine, :ets], fn mode ->
          {:ok, r1} = run_mmc(params, mode: mode, stop_time: 5_000.0)
          {:ok, r2} = run_mmc(params, mode: mode, stop_time: 5_000.0)

          r1.events == r2.events and
            r1.stats[:server].arrivals == r2.stats[:server].arrivals and
            r1.stats[:server].mean_wait == r2.stats[:server].mean_wait
        end)
      end
    end
  end

  describe "cross-mode equivalence (PropCheck)" do
    property "engine and ets produce identical results", numtests: 20 do
      forall params <- mmc_gen() do
        {:ok, r_eng} = run_mmc(params, mode: :engine, stop_time: 5_000.0)
        {:ok, r_ets} = run_mmc(params, mode: :ets, stop_time: 5_000.0)

        r_eng.events == r_ets.events and
          r_eng.stats[:server].arrivals == r_ets.stats[:server].arrivals and
          r_eng.stats[:server].departures == r_ets.stats[:server].departures and
          r_eng.stats[:server].mean_wait == r_ets.stats[:server].mean_wait
      end
    end
  end

  describe "DSL flow conservation (PropCheck)" do
    property "barbershop: arrivals == completed + in_progress", numtests: 50 do
      forall {seed, stop_time} <- dsl_gen() do
        {:ok, result} = Sim.PropertyModels.Barbershop.run(stop_time: stop_time, seed: seed)
        src = result.stats[:customer_source]
        cust = result.stats[:customer]
        src.total_arrivals == cust.completed + cust.in_progress
      end
    end
  end

  describe "edge cases (PropCheck)" do
    property "decide(0.0) routes nobody", numtests: 20 do
      forall {seed, stop_time} <- dsl_gen() do
        {:ok, result} = Sim.PropertyModels.NoRework.run(stop_time: stop_time, seed: seed)
        result.stats[:rework].grants == 0
      end
    end

    property "decide(1.0) routes everyone", numtests: 20 do
      forall {seed, stop_time} <- dsl_gen() do
        {:ok, result} = Sim.PropertyModels.AllRework.run(stop_time: stop_time, seed: seed)
        abs(result.stats[:rework].grants - result.stats[:part].completed) <= 1
      end
    end

    property "combine(1) is identity", numtests: 20 do
      forall {seed, stop_time} <- dsl_gen() do
        {:ok, result} = Sim.PropertyModels.Combine1.run(stop_time: stop_time, seed: seed)
        m = result.stats[:machine].grants
        c = result.stats[:part].completed
        ip = result.stats[:part].in_progress
        a = result.stats[:part_source].total_arrivals
        a == c + ip and m <= a and c <= m
      end
    end

    property "split(3)/combine(3) conserves entities", numtests: 20 do
      forall {seed, stop_time} <- dsl_gen() do
        {:ok, result} = Sim.PropertyModels.SplitCombine.run(stop_time: stop_time, seed: seed)
        cutter = result.stats[:cutter].grants
        assembler = result.stats[:assembler].grants
        expected = 3 * cutter
        diff = expected - assembler
        max_diff = max(12, trunc(expected * 0.05))
        diff >= 0 and diff <= max_diff
      end
    end
  end

  # ================================================================
  # STOCHASTIC PROPERTIES — hand-rolled harness (no shrinking)
  # PropCheck shrinking chases Monte Carlo noise, not bugs.
  # ================================================================

  alias Sim.PropertyHelper

  describe "Little's Law M/M/1 (stochastic)" do
    @tag timeout: 180_000
    test "mean sojourn time within 25% of theory across 30 random M/M/1 configs" do
      PropertyHelper.check(30, &PropertyHelper.gen_mm1/1, fn params ->
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

        w_obs = result.stats[:server].mean_wait + params.mu_inv
        rel = abs(w_obs - params.w_theory) / params.w_theory

        assert rel < 0.25,
               "W_obs=#{Float.round(w_obs, 3)}, W_theory=#{Float.round(params.w_theory, 3)}, " <>
                 "err=#{Float.round(rel * 100, 1)}%, rho=#{Float.round(params.rho, 3)}"
      end)
    end
  end

  describe "utilization (stochastic)" do
    @tag timeout: 180_000
    test "busy_time utilization within 20% of rho across 20 random M/M/1 configs" do
      PropertyHelper.check(20, &PropertyHelper.gen_mm1/1, fn params ->
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

        util = result.stats[:server].utilization
        rel = abs(util - params.rho) / params.rho

        assert rel < 0.20,
               "util=#{Float.round(util, 3)}, rho=#{Float.round(params.rho, 3)}, " <>
                 "err=#{Float.round(rel * 100, 1)}%"
      end)
    end
  end
end
