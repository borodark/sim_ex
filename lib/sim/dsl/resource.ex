defmodule Sim.DSL.Resource do
  @moduledoc """
  Resource entity for the DSL seize/release protocol.

  Supports static capacity and time-varying schedules:

      resource :barber, capacity: 1
      resource :machine, schedule: [{0..480, 3}, {480..960, 2}, {960..1440, 1}]

  With a schedule, capacity changes at time boundaries. When capacity
  increases (new shift arrives), queued requests are granted immediately.
  When capacity decreases (shift ends), busy count can temporarily exceed
  capacity — jobs in progress finish, but no new grants until busy drops
  below the new limit.
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :rand_state,
    :schedule,
    capacity: 1,
    busy: 0,
    queue: :queue.new(),
    grants: 0,
    releases: 0,
    last_capacity_check: 0
  ]

  # --- Init ---

  @impl true
  def init(%{schedule: schedule} = config) when is_list(schedule) do
    seed = config[:seed] || :erlang.phash2(config.id)

    {:ok,
     %__MODULE__{
       id: config.id,
       capacity: schedule_capacity(schedule, 0),
       schedule: schedule,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  def init(config) do
    seed = config[:seed] || :erlang.phash2(config.id)

    {:ok,
     %__MODULE__{
       id: config.id,
       capacity: config[:capacity] || 1,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  # --- Seize: capacity available → grant immediately ---

  @impl true
  def handle_event(
        {:seize_request, job_id, requestor_id},
        clock,
        %{busy: busy, capacity: cap} = state
      )
      when busy < cap do
    state = maybe_update_capacity(state, clock)

    if state.busy < state.capacity do
      grant_event = make_event(clock, requestor_id, {:grant, state.id, job_id})
      {:ok, %{state | busy: state.busy + 1, grants: state.grants + 1}, [grant_event]}
    else
      # Capacity changed between check — queue instead
      {:ok, %{state | queue: :queue.in({job_id, requestor_id}, state.queue)}, []}
    end
  end

  # --- Seize: at capacity → queue ---

  def handle_event({:seize_request, job_id, requestor_id}, clock, state) do
    state = maybe_update_capacity(state, clock)

    if state.busy < state.capacity do
      # Capacity increased via schedule — grant after all
      grant_event = make_event(clock, requestor_id, {:grant, state.id, job_id})
      {:ok, %{state | busy: state.busy + 1, grants: state.grants + 1}, [grant_event]}
    else
      {:ok, %{state | queue: :queue.in({job_id, requestor_id}, state.queue)}, []}
    end
  end

  # --- Release: free capacity, grant to next waiter ---

  def handle_event({:release, _job_id}, clock, state) do
    state = %{state | releases: state.releases + 1, busy: max(state.busy - 1, 0)}
    state = maybe_update_capacity(state, clock)
    grant_from_queue(state, clock)
  end

  # --- Catch-all ---

  def handle_event(_other, _clock, state), do: {:ok, state, []}

  # --- Statistics ---

  @impl true
  def statistics(%__MODULE__{} = state) do
    %{
      grants: state.grants,
      releases: state.releases,
      queue_length: :queue.len(state.queue),
      current_capacity: state.capacity,
      busy: state.busy
    }
  end

  # --- Private: grant from queue ---

  defp grant_from_queue(%{busy: busy, capacity: cap} = state, clock) when busy < cap do
    case :queue.out(state.queue) do
      {{:value, {job_id, requestor_id}}, queue} ->
        grant = make_event(clock, requestor_id, {:grant, state.id, job_id})
        state = %{state | queue: queue, busy: state.busy + 1, grants: state.grants + 1}
        # Recurse: capacity may allow more grants
        {:ok, state, more_grants} = grant_from_queue(state, clock)
        {:ok, state, [grant | more_grants]}

      {:empty, _} ->
        {:ok, state, []}
    end
  end

  defp grant_from_queue(state, _clock), do: {:ok, state, []}

  # --- Private: schedule capacity ---

  defp maybe_update_capacity(%{schedule: nil} = state, _clock), do: state

  defp maybe_update_capacity(%{schedule: schedule, capacity: old_cap} = state, clock) do
    new_cap = schedule_capacity(schedule, clock_to_number(clock))

    case new_cap do
      ^old_cap -> state
      _ -> %{state | capacity: new_cap, last_capacity_check: clock_to_number(clock)}
    end
  end

  defp schedule_capacity(schedule, t) do
    t_int = trunc(t)

    case find_in_schedule(schedule, t_int) do
      {:ok, cap} -> cap
      :not_found -> schedule_capacity_wrapped(schedule, t_int)
    end
  end

  defp find_in_schedule([], _t), do: :not_found

  defp find_in_schedule([{first..last//_, cap} | _rest], t)
       when t >= first and t <= last,
       do: {:ok, cap}

  defp find_in_schedule([_ | rest], t), do: find_in_schedule(rest, t)

  defp schedule_capacity_wrapped(schedule, t_int) do
    total = schedule |> Enum.map(fn {range, _} -> Range.size(range) end) |> Enum.sum()
    schedule_capacity_mod(schedule, t_int, total)
  end

  defp schedule_capacity_mod(_schedule, _t, 0), do: 1

  defp schedule_capacity_mod(schedule, t_int, total) do
    case find_in_schedule(schedule, rem(t_int, total)) do
      {:ok, cap} -> cap
      :not_found -> elem(hd(schedule), 1)
    end
  end

  # --- Private: clock format dispatch ---

  defp clock_to_number({tick, _diasca}), do: tick * 1.0
  defp clock_to_number(clock) when is_number(clock), do: clock * 1.0

  defp make_event({_tick, _diasca}, target, payload), do: {:same_tick, target, payload}
  defp make_event(clock, target, payload) when is_float(clock), do: {clock, target, payload}
end
