defmodule Sim.Warmup do
  @moduledoc """
  Warm-up detection for steady-state simulation.

  The first N observations are biased — the system starts empty and fills
  up. Welch's method (Law, Chapter 9) finds the truncation point: the
  index after which the moving average stabilizes.

  ## Usage

      observations = [12.3, 15.1, 8.7, ...]
      {steady_state, truncation} = Sim.Warmup.truncate(observations)
  """

  @doc """
  Detect warm-up truncation point via Welch's method.

  Returns `{:ok, index}` or `{:no_warmup, 0}`.

  ## Options

  - `:window` — moving average window (default: max(10, n/10))
  - `:threshold` — relative change for stability (default: 0.02)
  - `:min_steady` — consecutive stable windows needed (default: 5)
  """
  def detect(observations, opts \\ []) when is_list(observations) do
    n = length(observations)

    if n < 20 do
      {:no_warmup, 0}
    else
      window = opts[:window] || max(10, div(n, 10))
      threshold = opts[:threshold] || 0.02
      min_steady = opts[:min_steady] || 5

      ma = moving_average(observations, window: window)

      case find_stable_run(ma, threshold, min_steady) do
        {:found, idx} -> {:ok, idx}
        :not_found -> {:no_warmup, 0}
      end
    end
  end

  @doc """
  Centered moving average. Returns `[{index, value}, ...]`.
  """
  def moving_average(observations, opts \\ []) do
    window = opts[:window] || 10
    half = div(window, 2)

    observations
    |> Enum.chunk_every(window, 1, :discard)
    |> Enum.with_index(half)
    |> Enum.map(fn {chunk, idx} ->
      {idx, Enum.sum(chunk) / length(chunk)}
    end)
  end

  @doc """
  Detect and truncate. Returns `{steady_state_observations, truncation_index}`.
  """
  def truncate(observations, opts \\ []) do
    case detect(observations, opts) do
      {:ok, idx} -> {Enum.drop(observations, idx), idx}
      {:no_warmup, 0} -> {observations, 0}
    end
  end

  # --- Private: find consecutive stable windows ---

  defp find_stable_run(ma, threshold, min_steady) do
    values = Enum.map(ma, fn {_idx, val} -> val end)
    indices = Enum.map(ma, fn {idx, _val} -> idx end)

    changes =
      values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        if abs(a) > 1.0e-10, do: abs(b - a) / abs(a), else: 0.0
      end)

    find_run(changes, indices, threshold, min_steady, 0, 0)
  end

  defp find_run([], _indices, _threshold, _min_steady, _consecutive, _run_start) do
    :not_found
  end

  # NOTE on pattern-match refactor: kept as nested `if` intentionally.
  # Both conditions are pure numeric comparisons on computed values
  # (change vs threshold, counter vs min_steady). Lifting them into
  # head-dispatched helpers would thread 9 parameters through boolean
  # dispatcher functions. The iterative counter logic reads naturally
  # as a top-to-bottom if/else/recurse within a single clause.
  defp find_run([change | rest], [idx | rest_idx], threshold, min_steady, consecutive, run_start) do
    if change < threshold do
      new_consecutive = consecutive + 1
      new_start = if consecutive == 0, do: idx, else: run_start

      if new_consecutive >= min_steady do
        {:found, new_start}
      else
        find_run(rest, rest_idx, threshold, min_steady, new_consecutive, new_start)
      end
    else
      find_run(rest, rest_idx, threshold, min_steady, 0, 0)
    end
  end
end
