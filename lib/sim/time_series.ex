defmodule Sim.TimeSeries do
  @moduledoc """
  Time-window statistics collection for simulation output.

  Records events with timestamps, then computes metrics per window:
  utilization, throughput, queue length, wait time.

  ## Usage

      ts = Sim.TimeSeries.new(window_size: 480)  # 8-hour shifts
      ts = Sim.TimeSeries.record(ts, :arrive, 10.5)
      ts = Sim.TimeSeries.record(ts, :depart, 25.3)
      ts = Sim.TimeSeries.record(ts, :busy, 10.5, 25.3)  # busy from 10.5 to 25.3

      windows = Sim.TimeSeries.summarize(ts)
      # [%{window: 0, arrivals: 42, departures: 38, utilization: 0.73, ...}, ...]
  """

  defstruct [
    :window_size,
    events: [],
    busy_spans: [],
    queue_samples: []
  ]

  @doc "Create a new time series collector with given window size."
  def new(opts \\ []) do
    %__MODULE__{window_size: opts[:window_size] || 480.0}
  end

  @doc "Record a point event (arrival, departure) at a timestamp."
  def record(%__MODULE__{} = ts, type, time) when is_atom(type) and is_number(time) do
    %{ts | events: [{type, time} | ts.events]}
  end

  @doc "Record a busy span (resource occupied from `start` to `finish`)."
  def record(%__MODULE__{} = ts, :busy, start, finish)
      when is_number(start) and is_number(finish) do
    %{ts | busy_spans: [{start, finish} | ts.busy_spans]}
  end

  @doc "Record a queue length sample at a timestamp."
  def record_queue(%__MODULE__{} = ts, time, length)
      when is_number(time) and is_integer(length) do
    %{ts | queue_samples: [{time, length} | ts.queue_samples]}
  end

  @doc """
  Summarize into per-window statistics.

  Returns a list of maps, one per window:
  - `:window` — window index (0, 1, 2, ...)
  - `:start` / `:end` — time boundaries
  - `:arrivals` — count of arrival events
  - `:departures` — count of departure events
  - `:utilization` — fraction of window time a resource was busy
  - `:mean_queue` — average queue length (if queue samples provided)
  - `:throughput` — departures per window
  """
  def summarize(%__MODULE__{} = ts) do
    max_time = find_max_time(ts)
    n_windows = if max_time > 0, do: ceil(max_time / ts.window_size), else: 0

    for w <- 0..(n_windows - 1) do
      w_start = w * ts.window_size
      w_end = (w + 1) * ts.window_size

      arrivals = count_events(ts.events, :arrive, w_start, w_end)
      departures = count_events(ts.events, :depart, w_start, w_end)
      utilization = compute_utilization(ts.busy_spans, w_start, w_end, ts.window_size)
      mean_queue = compute_mean_queue(ts.queue_samples, w_start, w_end)

      %{
        window: w,
        start: w_start,
        end: w_end,
        arrivals: arrivals,
        departures: departures,
        throughput: departures,
        utilization: Float.round(utilization, 4),
        mean_queue: Float.round(mean_queue, 2)
      }
    end
  end

  @doc """
  Build a time series from a list of `{event_type, timestamp}` tuples.
  Convenience for post-processing simulation event logs.
  """
  def from_events(events, opts \\ []) when is_list(events) do
    ts = new(opts)
    Enum.reduce(events, ts, fn {type, time}, acc -> record(acc, type, time) end)
  end

  # --- Private ---

  defp find_max_time(ts) do
    event_max =
      case ts.events do
        [] -> 0
        evts -> evts |> Enum.map(fn {_, t} -> t end) |> Enum.max()
      end

    span_max =
      case ts.busy_spans do
        [] -> 0
        spans -> spans |> Enum.map(fn {_, t} -> t end) |> Enum.max()
      end

    max(event_max, span_max)
  end

  defp count_events(events, type, w_start, w_end) do
    Enum.count(events, fn {t, time} -> t == type and time >= w_start and time < w_end end)
  end

  defp compute_utilization([], _w_start, _w_end, _window_size), do: 0.0

  defp compute_utilization(spans, w_start, w_end, window_size) do
    busy_time =
      spans
      |> Enum.map(fn {s, f} ->
        # Clip span to window
        clipped_start = max(s, w_start)
        clipped_end = min(f, w_end)
        max(0, clipped_end - clipped_start)
      end)
      |> Enum.sum()

    busy_time / window_size
  end

  defp compute_mean_queue([], _w_start, _w_end), do: 0.0

  defp compute_mean_queue(samples, w_start, w_end) do
    samples
    |> Enum.filter(fn {t, _} -> t >= w_start and t < w_end end)
    |> mean_of_window()
  end

  # Pattern-matched dispatch: empty window → zero; non-empty → arithmetic mean.
  defp mean_of_window([]), do: 0.0

  defp mean_of_window(samples),
    do: Enum.sum(Enum.map(samples, fn {_, l} -> l end)) / length(samples)
end
