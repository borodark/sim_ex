defmodule Sim.Resource do
  @moduledoc """
  A capacity-limited resource (server, machine, workstation).

  Implements `Sim.Entity` behaviour. Entities arrive, queue if busy,
  get served for a random duration, then depart.

  This is the building block for queueing models (M/M/1, M/M/c, job shops).

  ## Configuration

      %{
        id: :server_1,
        capacity: 1,                          # parallel servers
        service: {:exponential, 0.5},         # {distribution, mean}
        seed: 42                              # optional PRNG seed
      }
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :service_dist,
    :service_mean,
    :rand_state,
    capacity: 1,
    busy: 0,
    queue: :queue.new(),
    # statistics
    arrivals: 0,
    departures: 0,
    busy_time: 0.0,
    wait_times: [],
    last_event_time: 0.0
  ]

  @impl true
  def init(config) do
    {dist, mean} = config[:service] || {:exponential, 1.0}
    seed = config[:seed] || :erlang.unique_integer([:positive])

    {:ok,
     %__MODULE__{
       id: config.id,
       capacity: config[:capacity] || 1,
       service_dist: dist,
       service_mean: mean,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  @impl true
  def handle_event({:arrive, job, arrival_time}, clock, state) do
    state = %{state | arrivals: state.arrivals + 1, last_event_time: clock}

    if state.busy < state.capacity do
      # serve immediately
      {service_time, rand_state} = sample_service(state)
      depart_time = clock + service_time

      state = %{
        state
        | busy: state.busy + 1,
          rand_state: rand_state,
          wait_times: [0.0 | state.wait_times]
      }

      events = [{depart_time, state.id, {:depart, job}}]
      {:ok, state, events}
    else
      # queue
      state = %{state | queue: :queue.in({job, arrival_time}, state.queue)}
      {:ok, state, []}
    end
  end

  def handle_event({:depart, _job}, clock, state) do
    state = %{state | departures: state.departures + 1, last_event_time: clock}

    case :queue.out(state.queue) do
      {{:value, {next_job, arrival_time}}, queue} ->
        wait = clock - arrival_time
        {service_time, rand_state} = sample_service(state)
        depart_time = clock + service_time

        state = %{
          state
          | queue: queue,
            rand_state: rand_state,
            wait_times: [wait | state.wait_times]
        }

        events = [{depart_time, state.id, {:depart, next_job}}]
        {:ok, state, events}

      {:empty, _queue} ->
        state = %{state | busy: state.busy - 1}
        {:ok, state, []}
    end
  end

  @impl true
  def statistics(state) do
    n = length(state.wait_times)
    mean_wait = if n > 0, do: Enum.sum(state.wait_times) / n, else: 0.0

    %{
      arrivals: state.arrivals,
      departures: state.departures,
      mean_wait: mean_wait,
      max_queue: :queue.len(state.queue),
      utilization:
        if(state.last_event_time > 0, do: state.busy_time / state.last_event_time, else: 0.0)
    }
  end

  # --- Private ---

  defp sample_service(%{service_dist: :exponential, service_mean: mean, rand_state: rs}) do
    {u, rs} = :rand.uniform_s(rs)
    {-mean * :math.log(u), rs}
  end

  defp sample_service(%{service_dist: :constant, service_mean: mean, rand_state: rs}) do
    {mean, rs}
  end
end
