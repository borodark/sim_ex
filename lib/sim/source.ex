defmodule Sim.Source do
  @moduledoc """
  Arrival generator — produces entities or events at random intervals.

  Supports stationary and non-stationary (scheduled) arrivals:

      # Stationary: constant rate
      %{interarrival: {:exponential, 1.0}}

      # Non-stationary: rate changes by time period
      %{interarrival: {:scheduled, [{0..479, {:exponential, 3.0}}, {480..959, {:exponential, 8.0}}]}}
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :target,
    :ia_dist,
    :ia_mean,
    :ia_schedule,
    :rand_state,
    :max_arrivals,
    count: 0
  ]

  # --- Init: scheduled arrivals ---

  @impl true
  def init(%{interarrival: {:scheduled, schedule}} = config) do
    seed = config[:seed] || :erlang.unique_integer([:positive])

    {:ok,
     %__MODULE__{
       id: config.id,
       target: config.target,
       ia_schedule: schedule,
       max_arrivals: config[:max_arrivals] || :infinity,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  # --- Init: stationary arrivals ---

  def init(config) do
    {dist, mean} = config[:interarrival] || {:exponential, 1.0}
    seed = config[:seed] || :erlang.unique_integer([:positive])

    {:ok,
     %__MODULE__{
       id: config.id,
       target: config.target,
       ia_dist: dist,
       ia_mean: mean,
       max_arrivals: config[:max_arrivals] || :infinity,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  # --- Generate: diasca mode ---

  @impl true
  def handle_event(:generate, {_tick, _diasca} = clock, state) do
    state = %{state | count: state.count + 1}
    {interval, rand_state} = sample_interarrival(state, clock)
    delay_ticks = max(1, round(interval))

    arrival = {:same_tick, state.target, {:arrive, state.count, clock}}
    next = {:delay, delay_ticks, state.id, :generate}

    maybe_cap(%{state | rand_state: rand_state}, [arrival, next])
  end

  # --- Generate: float mode ---

  def handle_event(:generate, clock, state) when is_float(clock) do
    state = %{state | count: state.count + 1}
    {interval, rand_state} = sample_interarrival(state, clock)

    arrival = {clock, state.target, {:arrive, state.count, clock}}
    next = {clock + interval, state.id, :generate}

    maybe_cap(%{state | rand_state: rand_state}, [arrival, next])
  end

  @impl true
  def statistics(state), do: %{total_arrivals: state.count}

  # --- Private: cap at max_arrivals ---

  defp maybe_cap(%{max_arrivals: :infinity} = state, [arrival, next]) do
    {:ok, state, [arrival, next]}
  end

  defp maybe_cap(%{count: count, max_arrivals: max} = state, [arrival, _next])
       when count >= max do
    {:ok, state, [arrival]}
  end

  defp maybe_cap(state, events), do: {:ok, state, events}

  # --- Private: sample interarrival ---

  defp sample_interarrival(
         %{ia_schedule: nil, ia_dist: dist, ia_mean: mean, rand_state: rs},
         _clock
       ) do
    sample_dist(dist, mean, rs)
  end

  defp sample_interarrival(%{ia_schedule: schedule, rand_state: rs}, clock) do
    {dist, mean} = find_current_rate(schedule, clock_to_int(clock))
    sample_dist(dist, mean, rs)
  end

  # --- Private: find rate in schedule ---

  defp find_current_rate([], _t), do: {:exponential, 1.0}

  defp find_current_rate([{first..last//_, {dist, mean}} | _rest], t)
       when t >= first and t <= last do
    {dist, mean}
  end

  defp find_current_rate([_ | rest], t), do: find_current_rate(rest, t)

  # --- Private: distribution sampling ---

  defp sample_dist(:exponential, mean, rs) do
    {u, rs} = :rand.uniform_s(rs)
    {-mean * :math.log(u), rs}
  end

  defp sample_dist(:constant, mean, rs), do: {mean, rs}

  defp sample_dist(:uniform, {a, b}, rs) do
    {u, rs} = :rand.uniform_s(rs)
    {a + u * (b - a), rs}
  end

  # --- Private: clock to integer ---

  defp clock_to_int({tick, _diasca}), do: tick
  defp clock_to_int(clock) when is_number(clock), do: trunc(clock)
end
