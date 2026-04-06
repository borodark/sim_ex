defmodule Sim.Experiment do
  @moduledoc """
  Experimental design for simulation studies.

  Supports Law's recommended methods:
  - **Independent replications**: run the same model N times with different seeds
  - **Common random numbers (CRN)**: compare two configurations with the same
    seed sequence to reduce variance
  - **Paired comparison**: CRN + paired t-test

  ## Example

      # Compare two configurations
      results = Sim.Experiment.compare(
        config_a: fn seed -> run_system(config_a, seed) end,
        config_b: fn seed -> run_system(config_b, seed) end,
        seeds: 1..30,
        metric: :mean_wait
      )
      # => %{mean_diff: -0.12, ci: {-0.18, -0.06}, significant: true}
  """

  @doc """
  Run `n` independent replications of a simulation.

  `run_fn` receives a seed integer and returns a map of metrics.
  Returns list of metric maps.

  Parallel by default — uses all available schedulers. Pass `parallel: false`
  for sequential execution (deterministic ordering, debugging).

  ## Options

  - `:parallel` — run replications in parallel (default: `true`)
  - `:max_concurrency` — max parallel tasks (default: `System.schedulers_online()`)
  - `:base_seed` — starting seed (default: 1)
  - `:timeout` — per-task timeout (default: `:infinity`)
  """
  def replicate(run_fn, n, opts \\ []) do
    base_seed = opts[:base_seed] || 1
    parallel = Keyword.get(opts, :parallel, true)

    seeds = base_seed..(base_seed + n - 1)

    if parallel do
      seeds
      |> Task.async_stream(fn seed -> run_fn.(seed) end,
        max_concurrency: opts[:max_concurrency] || System.schedulers_online(),
        timeout: opts[:timeout] || :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
    else
      Enum.map(seeds, fn seed -> run_fn.(seed) end)
    end
  end

  @doc """
  Compare two configurations using common random numbers.

  Returns `%{mean_a, mean_b, mean_diff, ci, significant}`.
  """
  def compare(opts) do
    run_a = Keyword.fetch!(opts, :config_a)
    run_b = Keyword.fetch!(opts, :config_b)
    seeds = Keyword.fetch!(opts, :seeds)
    metric = Keyword.fetch!(opts, :metric)
    alpha = opts[:alpha] || 0.05
    parallel = Keyword.get(opts, :parallel, true)

    pairs =
      if parallel do
        seeds
        |> Task.async_stream(fn seed ->
          a = run_a.(seed)
          b = run_b.(seed)
          {Map.fetch!(a, metric), Map.fetch!(b, metric)}
        end, max_concurrency: System.schedulers_online(), timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)
      else
        Enum.map(seeds, fn seed ->
          a = run_a.(seed)
          b = run_b.(seed)
          {Map.fetch!(a, metric), Map.fetch!(b, metric)}
        end)
      end

    diffs = Enum.map(pairs, fn {a, b} -> a - b end)
    n = length(diffs)
    mean_diff = Enum.sum(diffs) / n
    var_diff = Enum.reduce(diffs, 0.0, fn d, acc -> acc + (d - mean_diff) ** 2 end) / (n - 1)
    se = :math.sqrt(var_diff / n)

    t = t_quantile(n - 1, 1 - alpha / 2)
    ci = {mean_diff - t * se, mean_diff + t * se}

    {lo, hi} = ci
    significant = lo > 0 or hi < 0

    means_a = Enum.map(pairs, fn {a, _} -> a end)
    means_b = Enum.map(pairs, fn {_, b} -> b end)

    %{
      mean_a: Enum.sum(means_a) / n,
      mean_b: Enum.sum(means_b) / n,
      mean_diff: mean_diff,
      ci: ci,
      alpha: alpha,
      significant: significant,
      n: n
    }
  end

  @doc """
  Summary statistics for a list of numeric values.
  """
  def summary(values) when is_list(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) ** 2 end) / (n - 1)

    %{
      n: n,
      mean: mean,
      std: :math.sqrt(variance),
      min: Enum.min(values),
      max: Enum.max(values)
    }
  end

  # Same approximation as Statistics module
  defp t_quantile(df, p) when df > 0 and p > 0.5 and p < 1.0 do
    z = :math.sqrt(2.0) * erf_inv(2 * p - 1)
    g1 = (z * z * z + z) / (4 * df)
    g2 = (5 * :math.pow(z, 5) + 16 * z * z * z + 3 * z) / (96 * df * df)
    z + g1 + g2
  end

  defp t_quantile(_df, _p), do: 1.96

  defp erf_inv(x) when x > -1 and x < 1 do
    a = 0.147
    ln = :math.log(1 - x * x)
    s = if x >= 0, do: 1, else: -1
    t1 = 2.0 / (:math.pi() * a) + ln / 2.0
    s * :math.sqrt(:math.sqrt(t1 * t1 - ln / a) - t1)
  end
end
