defmodule Sim.DSL.Conveyor do
  @moduledoc """
  Conveyor entity for the DSL transport verb.

  A conveyor is a capacity-limited delay. Unlike `route` (a simple delay),
  a conveyor has finite length, speed, and a maximum number of items that
  can be on it simultaneously. When full, new items queue at the entrance.

      conveyor :belt, length: 100, speed: 10, capacity: 50

  Transit time is deterministic: `length / speed`. When an item boards,
  a self-event is scheduled at `clock + length/speed`. When the conveyor
  is at capacity, arriving items wait in a FIFO queue and board as space
  becomes available.
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :length,
    :speed,
    capacity: 10,
    in_transit: %{},
    queue: :queue.new(),
    completed: 0,
    total_transit_time: 0.0
  ]

  @impl true
  def init(config) do
    {:ok,
     %__MODULE__{
       id: config.id,
       length: config.length,
       speed: config.speed,
       capacity: config[:capacity] || 10
     }}
  end

  # --- Board request: capacity available -> grant immediately ---

  @impl true
  def handle_event({:board_request, job_id, requestor_id}, clock, state) do
    if map_size(state.in_transit) < state.capacity do
      board_item(job_id, requestor_id, clock, state)
    else
      {:ok, %{state | queue: :queue.in({job_id, requestor_id}, state.queue)}, []}
    end
  end

  # --- Transit complete: item reached end of belt ---

  def handle_event({:transit_complete, job_id}, clock, state) do
    case Map.get(state.in_transit, job_id) do
      nil ->
        {:ok, state, []}

      {requestor_id, board_time, _exit_time} ->
        transit_time = clock_to_float(clock) - board_time

        state = %{
          state
          | in_transit: Map.delete(state.in_transit, job_id),
            completed: state.completed + 1,
            total_transit_time: state.total_transit_time + transit_time
        }

        complete_event = make_event(clock, requestor_id, {:transport_complete, state.id, job_id})

        # Try to board from queue
        {state, queue_events} = board_from_queue(clock, state)

        {:ok, state, [complete_event | queue_events]}
    end
  end

  # --- Catch-all ---

  def handle_event(_other, _clock, state), do: {:ok, state, []}

  # --- Statistics ---

  @impl true
  def statistics(%__MODULE__{} = state) do
    n = state.completed

    %{
      completed: state.completed,
      in_transit: map_size(state.in_transit),
      queued: :queue.len(state.queue),
      mean_transit: if(n > 0, do: state.total_transit_time / n, else: 0.0),
      capacity: state.capacity
    }
  end

  # --- Private ---

  defp board_item(job_id, requestor_id, clock, state) do
    board_time = clock_to_float(clock)
    transit_duration = state.length / state.speed
    exit_time = board_time + transit_duration

    state = %{
      state
      | in_transit: Map.put(state.in_transit, job_id, {requestor_id, board_time, exit_time})
    }

    grant_event = make_event(clock, requestor_id, {:board_grant, state.id, job_id})
    transit_event = {exit_time, state.id, {:transit_complete, job_id}}

    {:ok, state, [grant_event, transit_event]}
  end

  defp board_from_queue(clock, state) do
    board_if_capacity(
      map_size(state.in_transit) < state.capacity,
      clock,
      state
    )
  end

  # At capacity → no boarding.
  defp board_if_capacity(false, _clock, state), do: {state, []}

  # Capacity available → try to pop from queue.
  defp board_if_capacity(true, clock, state) do
    state.queue |> :queue.out() |> board_from_pop(clock, state)
  end

  # Queue empty → done.
  defp board_from_pop({:empty, _}, _clock, state), do: {state, []}

  # Queue had an item → board it and recurse for more.
  defp board_from_pop({{:value, {job_id, requestor_id}}, queue}, clock, state) do
    state = %{state | queue: queue}
    {:ok, state, events} = board_item(job_id, requestor_id, clock, state)
    {more_state, more_events} = board_from_queue(clock, state)
    {more_state, events ++ more_events}
  end

  defp clock_to_float({tick, _diasca}), do: tick * 1.0
  defp clock_to_float(clock) when is_number(clock), do: clock * 1.0

  defp make_event({_tick, _diasca}, target, payload), do: {:same_tick, target, payload}
  defp make_event(clock, target, payload) when is_float(clock), do: {clock, target, payload}
end
