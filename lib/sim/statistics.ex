defmodule Sim.Statistics do
  @moduledoc """
  Streaming statistics collector using Welford's online algorithm.

  Computes mean, variance, min, max without storing raw data.
  Supports batch means for steady-state confidence intervals
  (Law, Chapter 9).

  ## Batch means method

  Divide a long run into `k` batches of `m` observations each.
  Compute mean of each batch. Treat batch means as independent
  observations → standard t-confidence interval. Requires
  `k >= 30` and `m` large enough that batch means are approximately
  independent.
  """

  use GenServer

  defstruct metrics: %{}

  defmodule Metric do
    @moduledoc false
    defstruct n: 0,
              mean: 0.0,
              m2: 0.0,
              min: :infinity,
              max: :neg_infinity,
              batch_size: nil,
              batch_acc: 0.0,
              batch_n: 0,
              batch_means: []
  end

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Record an observation for a metric."
  def record(server \\ __MODULE__, metric_name, value) do
    GenServer.cast(server, {:record, metric_name, value})
  end

  @doc "Get current statistics for a metric."
  def get(server \\ __MODULE__, metric_name) do
    GenServer.call(server, {:get, metric_name})
  end

  @doc "Get statistics for all metrics."
  def all(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  @doc """
  Confidence interval for the mean using batch means.
  Returns `{lower, mean, upper}` or `{:error, reason}`.
  """
  def confidence_interval(server \\ __MODULE__, metric_name, alpha \\ 0.05) do
    GenServer.call(server, {:ci, metric_name, alpha})
  end

  # --- Server ---

  @impl true
  def init(opts) do
    batch_size = opts[:batch_size]
    {:ok, %__MODULE__{metrics: %{}}, {:continue, {:batch_size, batch_size}}}
  end

  @impl true
  def handle_continue({:batch_size, _bs}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:record, name, value}, state) when is_number(value) do
    metric = Map.get(state.metrics, name, %Metric{})
    metric = welford_update(metric, value)
    {:noreply, %{state | metrics: Map.put(state.metrics, name, metric)}}
  end

  def handle_cast({:record, _name, _value}, state), do: {:noreply, state}

  @impl true
  def handle_call({:get, name}, _from, state) do
    case Map.get(state.metrics, name) do
      nil -> {:reply, nil, state}
      metric -> {:reply, metric_summary(metric), state}
    end
  end

  def handle_call(:all, _from, state) do
    summaries = Map.new(state.metrics, fn {name, metric} -> {name, metric_summary(metric)} end)
    {:reply, summaries, state}
  end

  def handle_call({:ci, name, alpha}, _from, state) do
    case Map.get(state.metrics, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{batch_means: means} when length(means) >= 2 ->
        {:reply, batch_means_ci(means, alpha), state}

      %{n: n} when n >= 2 ->
        # Fallback: treat all observations as single batch
        metric = Map.get(state.metrics, name)
        {:reply, single_run_ci(metric, alpha), state}

      _ ->
        {:reply, {:error, :insufficient_data}, state}
    end
  end

  # --- Welford ---

  defp welford_update(metric, value) do
    n = metric.n + 1
    delta = value - metric.mean
    mean = metric.mean + delta / n
    delta2 = value - mean
    m2 = metric.m2 + delta * delta2
    min = if value < metric.min, do: value, else: metric.min
    max = if value > metric.max, do: value, else: metric.max

    %{metric | n: n, mean: mean, m2: m2, min: min, max: max}
    |> accumulate_batch(value)
  end

  # No batch accumulation configured (batch_size is nil).
  defp accumulate_batch(%{batch_size: nil} = metric, _value), do: metric

  # Batch accumulation: add value to running batch, check for completion.
  defp accumulate_batch(metric, value) do
    batch_n = metric.batch_n + 1
    batch_acc = metric.batch_acc + value
    check_batch_complete(batch_n, batch_acc, metric)
  end

  # Batch full → compute mean and reset accumulator.
  defp check_batch_complete(batch_n, batch_acc, %{batch_size: batch_size} = metric)
       when batch_n >= batch_size do
    batch_mean = batch_acc / batch_n
    %{metric | batch_n: 0, batch_acc: 0.0, batch_means: [batch_mean | metric.batch_means]}
  end

  # Batch not yet full → update running accumulator.
  defp check_batch_complete(batch_n, batch_acc, metric) do
    %{metric | batch_n: batch_n, batch_acc: batch_acc}
  end

  defp metric_summary(%Metric{n: 0}), do: %{n: 0}

  defp metric_summary(metric) do
    variance = if metric.n > 1, do: metric.m2 / (metric.n - 1), else: 0.0

    %{
      n: metric.n,
      mean: metric.mean,
      variance: variance,
      std: :math.sqrt(variance),
      min: metric.min,
      max: metric.max
    }
  end

  defp batch_means_ci(means, alpha) do
    k = length(means)
    grand_mean = Enum.sum(means) / k
    variance = Enum.reduce(means, 0.0, fn m, acc -> acc + (m - grand_mean) ** 2 end) / (k - 1)
    se = :math.sqrt(variance / k)
    t = t_quantile(k - 1, 1 - alpha / 2)
    {grand_mean - t * se, grand_mean, grand_mean + t * se}
  end

  defp single_run_ci(metric, alpha) do
    se = :math.sqrt(metric.m2 / (metric.n * (metric.n - 1)))
    t = t_quantile(metric.n - 1, 1 - alpha / 2)
    {metric.mean - t * se, metric.mean, metric.mean + t * se}
  end

  # Approximate t-quantile (Abramowitz & Stegun 26.2.17)
  defp t_quantile(df, p) when df > 0 and p > 0.5 and p < 1.0 do
    # Normal quantile approximation
    z = :math.sqrt(2.0) * erf_inv(2 * p - 1)

    # Cornish-Fisher expansion for small df
    g1 = (z * z * z + z) / (4 * df)
    g2 = (5 * :math.pow(z, 5) + 16 * z * z * z + 3 * z) / (96 * df * df)
    z + g1 + g2
  end

  defp t_quantile(_df, _p), do: 1.96

  # Inverse error function (Winitzki 2008 approximation)
  defp erf_inv(x) when x > -1 and x < 1 do
    a = 0.147
    ln = :math.log(1 - x * x)
    s = if x >= 0, do: 1, else: -1
    t1 = 2.0 / (:math.pi() * a) + ln / 2.0
    s * :math.sqrt(:math.sqrt(t1 * t1 - ln / a) - t1)
  end
end
