defmodule Sim.Source do
  @moduledoc """
  Arrival generator — produces entities or events at random intervals.

  Implements `Sim.Entity` behaviour. Generates arrivals for a target
  entity (typically a `Sim.Resource`) according to a configured
  inter-arrival time distribution.

  ## Configuration

      %{
        id: :arrivals,
        target: :server_1,
        interarrival: {:exponential, 1.0},    # {distribution, mean}
        seed: 123,
        max_arrivals: :infinity               # optional cap
      }
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :target,
    :ia_dist,
    :ia_mean,
    :rand_state,
    :max_arrivals,
    count: 0
  ]

  @impl true
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

  @impl true
  def handle_event(:generate, clock, state) do
    state = %{state | count: state.count + 1}

    {interval, rand_state} = sample_interarrival(state)

    # Build events based on clock format (float vs diasca tuple)
    {arrival_event, next_event} =
      case clock do
        {_tick, _diasca} ->
          # Diasca mode: arrival at same tick, next generate at future tick
          delay_ticks = max(1, round(interval))

          {{:same_tick, state.target, {:arrive, state.count, clock}},
           {:delay, delay_ticks, state.id, :generate}}

        _ ->
          # Float mode
          {{clock, state.target, {:arrive, state.count, clock}},
           {clock + interval, state.id, :generate}}
      end

    if state.max_arrivals != :infinity and state.count >= state.max_arrivals do
      {:ok, %{state | rand_state: rand_state}, [arrival_event]}
    else
      {:ok, %{state | rand_state: rand_state}, [arrival_event, next_event]}
    end
  end

  @impl true
  def statistics(state) do
    %{total_arrivals: state.count}
  end

  # --- Private ---

  defp sample_interarrival(%{ia_dist: :exponential, ia_mean: mean, rand_state: rs}) do
    {u, rs} = :rand.uniform_s(rs)
    {-mean * :math.log(u), rs}
  end

  defp sample_interarrival(%{ia_dist: :constant, ia_mean: mean, rand_state: rs}) do
    {mean, rs}
  end
end
