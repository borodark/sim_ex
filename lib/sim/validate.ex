defmodule Sim.Validate do
  @moduledoc """
  Compare simulation output to historical data.

  A model that disagrees with last month's production data is not a model.
  It is a wish. This module provides quantitative validation methods.

  ## Usage

      historical = [127, 131, 125, 129, 133, ...]  # actual parts per shift
      simulated = [128.4, 130.1, 126.7, ...]         # simulation output

      report = Sim.Validate.compare(historical, simulated)
      # %{
      #   mean_error: 0.8,
      #   mean_abs_error: 2.1,
      #   mean_pct_error: 1.6,
      #   within_5pct: 94.0,
      #   within_10pct: 100.0,
      #   ks_statistic: 0.12,
      #   verdict: :valid
      # }
  """

  @doc """
  Compare simulated output to historical observations.

  Returns a validation report with error metrics and a verdict.

  ## Options

  - `:tolerance` — maximum acceptable mean percent error (default: 10.0)
  - `:ks_threshold` — KS statistic threshold for distributional match (default: 0.2)
  """
  def compare(historical, simulated, opts \\ [])
      when is_list(historical) and is_list(simulated) do
    tolerance = opts[:tolerance] || 10.0
    ks_threshold = opts[:ks_threshold] || 0.2

    n_hist = length(historical)
    n_sim = length(simulated)

    hist_f = Enum.map(historical, &(&1 * 1.0))
    sim_f = Enum.map(simulated, &(&1 * 1.0))

    # Paired errors (use shorter list)
    n_paired = min(n_hist, n_sim)

    errors =
      Enum.zip(Enum.take(hist_f, n_paired), Enum.take(sim_f, n_paired))
      |> Enum.map(fn {h, s} -> s - h end)

    abs_errors = Enum.map(errors, &abs/1)

    pct_errors =
      Enum.zip(Enum.take(hist_f, n_paired), errors)
      |> Enum.map(fn {h, e} -> if abs(h) > 1.0e-10, do: abs(e) / abs(h) * 100, else: 0.0 end)

    mean_error = safe_mean(errors)
    mean_abs_error = safe_mean(abs_errors)
    mean_pct_error = safe_mean(pct_errors)

    within_5 = Enum.count(pct_errors, &(&1 <= 5.0)) / max(n_paired, 1) * 100
    within_10 = Enum.count(pct_errors, &(&1 <= 10.0)) / max(n_paired, 1) * 100

    # KS statistic (two-sample)
    ks = ks_statistic(hist_f, sim_f)

    # Verdict
    verdict =
      cond do
        mean_pct_error <= tolerance and ks <= ks_threshold -> :valid
        mean_pct_error <= tolerance * 1.5 and ks <= ks_threshold * 1.5 -> :marginal
        true -> :invalid
      end

    %{
      n_historical: n_hist,
      n_simulated: n_sim,
      n_paired: n_paired,
      mean_error: Float.round(mean_error, 2),
      mean_abs_error: Float.round(mean_abs_error, 2),
      mean_pct_error: Float.round(mean_pct_error, 1),
      within_5pct: Float.round(within_5, 1),
      within_10pct: Float.round(within_10, 1),
      ks_statistic: Float.round(ks, 4),
      hist_mean: Float.round(safe_mean(hist_f), 2),
      sim_mean: Float.round(safe_mean(sim_f), 2),
      verdict: verdict
    }
  end

  @doc """
  Print a human-readable validation report.
  """
  def report(historical, simulated, opts \\ []) do
    r = compare(historical, simulated, opts)

    verdict_str =
      case r.verdict do
        :valid -> "VALID — model matches data"
        :marginal -> "MARGINAL — model approximately matches data"
        :invalid -> "INVALID — model does not match data"
      end

    IO.puts("Validation Report")
    IO.puts(String.duplicate("═", 45))
    IO.puts("  Historical: #{r.n_historical} observations, mean #{r.hist_mean}")
    IO.puts("  Simulated:  #{r.n_simulated} observations, mean #{r.sim_mean}")
    IO.puts("")
    IO.puts("  Mean error:     #{r.mean_error}")
    IO.puts("  Mean |error|:   #{r.mean_abs_error}")
    IO.puts("  Mean % error:   #{r.mean_pct_error}%")
    IO.puts("  Within 5%:      #{r.within_5pct}%")
    IO.puts("  Within 10%:     #{r.within_10pct}%")
    IO.puts("  KS statistic:   #{r.ks_statistic}")
    IO.puts("")
    IO.puts("  Verdict: #{verdict_str}")
    IO.puts(String.duplicate("═", 45))

    r
  end

  # --- Private ---

  defp safe_mean([]), do: 0.0
  defp safe_mean(list), do: Enum.sum(list) / length(list)

  # Two-sample Kolmogorov-Smirnov statistic.
  # Empty-list boundary handled at the head — no wasted sort.
  defp ks_statistic([], _b), do: 1.0
  defp ks_statistic(_a, []), do: 1.0

  defp ks_statistic(a, b) do
    sa = Enum.sort(a)
    sb = Enum.sort(b)
    na = length(sa)
    nb = length(sb)

    # Merge and compute max difference of empirical CDFs
    all_values = Enum.uniq(Enum.sort(sa ++ sb))

    all_values
    |> Enum.map(fn v ->
      cdf_a = Enum.count(sa, &(&1 <= v)) / na
      cdf_b = Enum.count(sb, &(&1 <= v)) / nb
      abs(cdf_a - cdf_b)
    end)
    |> Enum.max()
  end
end
