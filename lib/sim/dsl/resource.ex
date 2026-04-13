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

  ## Preemptive Resources

      resource :machine, capacity: 1, preemptive: true

  When `preemptive: true`, higher-priority entities can eject current
  holders. Priority is numeric (lower = higher priority). The ejected
  entity receives a `{:preempted, resource_name, job_id, remaining_service}`
  message and re-enters the queue with its remaining service time.

  Queue ordering uses `{priority, queue_seq}` via `:gb_trees` to ensure
  FIFO within the same priority level.
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :rand_state,
    :schedule,
    capacity: 1,
    preemptive: false,
    busy: 0,
    queue: :queue.new(),
    # %{job_id => {requestor_id, priority, grant_time}} — preemptive mode only
    holders: %{},
    grants: 0,
    releases: 0,
    preemptions: 0,
    queue_seq: 0,
    last_capacity_check: 0
  ]

  # --- Init ---

  @impl true
  def init(%{schedule: schedule} = config) when is_list(schedule) do
    seed = config[:seed] || :erlang.phash2(config.id)
    preemptive = config[:preemptive] || false

    state = %__MODULE__{
      id: config.id,
      capacity: schedule_capacity(schedule, 0),
      schedule: schedule,
      preemptive: preemptive,
      rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    }

    state = if preemptive, do: %{state | queue: :gb_trees.empty()}, else: state
    {:ok, state}
  end

  def init(config) do
    seed = config[:seed] || :erlang.phash2(config.id)
    preemptive = config[:preemptive] || false

    state = %__MODULE__{
      id: config.id,
      capacity: config[:capacity] || 1,
      preemptive: preemptive,
      rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    }

    state = if preemptive, do: %{state | queue: :gb_trees.empty()}, else: state
    {:ok, state}
  end

  # ============================================================
  # Non-preemptive: 3-tuple seize_request (backward compat)
  # ============================================================

  @impl true
  def handle_event(
        {:seize_request, job_id, requestor_id},
        clock,
        %{preemptive: false} = state
      ) do
    handle_seize_non_preemptive(job_id, requestor_id, clock, state)
  end

  # 4-tuple on a non-preemptive resource: ignore priority, treat as non-preemptive
  def handle_event(
        {:seize_request, job_id, requestor_id, _priority},
        clock,
        %{preemptive: false} = state
      ) do
    handle_seize_non_preemptive(job_id, requestor_id, clock, state)
  end

  # ============================================================
  # Preemptive: 4-tuple seize_request
  # ============================================================

  def handle_event(
        {:seize_request, job_id, requestor_id, priority},
        clock,
        %{preemptive: true} = state
      ) do
    handle_seize_preemptive(job_id, requestor_id, priority, clock, state)
  end

  # 3-tuple on preemptive resource: default priority 999
  def handle_event(
        {:seize_request, job_id, requestor_id},
        clock,
        %{preemptive: true} = state
      ) do
    handle_seize_preemptive(job_id, requestor_id, 999, clock, state)
  end

  # ============================================================
  # Release (same for both modes)
  # ============================================================

  def handle_event({:release, job_id}, clock, %{preemptive: true} = state) do
    if Map.has_key?(state.holders, job_id) do
      state = %{state | releases: state.releases + 1, busy: state.busy - 1}
      state = %{state | holders: Map.delete(state.holders, job_id)}
      state = maybe_update_capacity(state, clock)
      grant_from_queue_preemptive(state, clock)
    else
      {:ok, state, []}
    end
  end

  def handle_event({:release, _job_id}, clock, %{busy: busy} = state) when busy > 0 do
    state = %{state | releases: state.releases + 1, busy: busy - 1}
    state = maybe_update_capacity(state, clock)
    grant_from_queue(state, clock)
  end

  def handle_event({:release, _job_id}, _clock, state) do
    {:ok, state, []}
  end

  # --- Catch-all ---

  def handle_event(_other, _clock, state), do: {:ok, state, []}

  # --- Statistics ---

  @impl true
  def statistics(%__MODULE__{preemptive: true} = state) do
    %{
      grants: state.grants,
      releases: state.releases,
      queue_length: :gb_trees.size(state.queue),
      current_capacity: state.capacity,
      busy: state.busy,
      preemptions: state.preemptions
    }
  end

  def statistics(%__MODULE__{} = state) do
    %{
      grants: state.grants,
      releases: state.releases,
      queue_length: :queue.len(state.queue),
      current_capacity: state.capacity,
      busy: state.busy
    }
  end

  # ============================================================
  # Private: non-preemptive seize (original logic)
  # ============================================================

  defp handle_seize_non_preemptive(job_id, requestor_id, clock, state) do
    state = maybe_update_capacity(state, clock)

    if state.busy < state.capacity do
      grant_event = make_event(clock, requestor_id, {:grant, state.id, job_id})
      {:ok, %{state | busy: state.busy + 1, grants: state.grants + 1}, [grant_event]}
    else
      {:ok, %{state | queue: :queue.in({job_id, requestor_id}, state.queue)}, []}
    end
  end

  # ============================================================
  # Private: preemptive seize
  # ============================================================
  #
  # NOTE on pattern-match refactor: attempted to split this into
  # `grant_or_queue/4` + `try_preempt_or_enqueue/4` pattern-matched
  # helpers. The result was 4 functions with 5 clauses each carrying
  # a 4-arg parameter list, plus a new `req` tuple abstraction.
  # Verdict: the branches are single-call-site dispatchers, the
  # parameter-threading ceremony outweighed the clarity gain, and
  # the linear decision tree (capacity → preempt check → enqueue)
  # reads more coherently top-to-bottom here than fragmented across
  # helpers. Kept as-is per the "when NOT to apply" clause of the
  # defp pattern-match rule. This function is also guarded by the
  # Resource model in test/statham_test.exs — the same module whose
  # ungranted-release bug was the subject of the "Release That Never
  # Seized" post (Apr 2026). Any future refactor here must re-run
  # that property suite.
  # ============================================================

  defp handle_seize_preemptive(job_id, requestor_id, priority, clock, state) do
    state = maybe_update_capacity(state, clock)

    if state.busy < state.capacity do
      # Capacity available — grant immediately
      grant_event = make_event(clock, requestor_id, {:grant, state.id, job_id})
      holders = Map.put(state.holders, job_id, {requestor_id, priority, clock_to_number(clock)})

      {:ok, %{state | busy: state.busy + 1, grants: state.grants + 1, holders: holders},
       [grant_event]}
    else
      # At capacity — check if incoming priority beats worst holder
      case find_worst_holder(state.holders) do
        {worst_job_id, {worst_requestor_id, worst_priority, _grant_time}}
        when priority < worst_priority ->
          # Preempt: eject worst holder, grant to incoming
          now = clock_to_number(clock)
          remaining = compute_remaining(state.holders, worst_job_id, now)

          # Remove worst holder
          holders = Map.delete(state.holders, worst_job_id)

          # Add incoming as new holder
          holders = Map.put(holders, job_id, {requestor_id, priority, now})

          # Send preempted event to the ejected entity's process
          preempted_event =
            make_event(
              clock,
              worst_requestor_id,
              {:preempted, state.id, worst_job_id, remaining}
            )

          # Grant to incoming
          grant_event = make_event(clock, requestor_id, {:grant, state.id, job_id})

          # Re-queue the ejected entity with its remaining service time
          seq = state.queue_seq

          queue =
            :gb_trees.insert(
              {worst_priority, seq},
              {worst_job_id, worst_requestor_id, remaining},
              state.queue
            )

          {:ok,
           %{
             state
             | holders: holders,
               grants: state.grants + 1,
               preemptions: state.preemptions + 1,
               queue: queue,
               queue_seq: seq + 1
           }, [grant_event, preempted_event]}

        _ ->
          # Incoming does NOT beat worst holder — enqueue
          seq = state.queue_seq
          queue = :gb_trees.insert({priority, seq}, {job_id, requestor_id, nil}, state.queue)
          {:ok, %{state | queue: queue, queue_seq: seq + 1}, []}
      end
    end
  end

  # Find the holder with worst (highest numeric) priority
  defp find_worst_holder(holders) when map_size(holders) == 0, do: nil

  defp find_worst_holder(holders) do
    Enum.max_by(holders, fn {_job_id, {_req_id, priority, _gt}} -> priority end)
  end

  # Compute remaining service time for a preempted holder.
  # We don't know the original hold duration from the resource side,
  # so remaining is nil here — the process tracks its own remaining time
  # via hold_gen and the preempted event.
  defp compute_remaining(_holders, _job_id, _now), do: nil

  # ============================================================
  # Private: grant from queue (non-preemptive)
  # ============================================================

  defp grant_from_queue(%{busy: busy, capacity: cap} = state, clock) when busy < cap do
    state.queue |> :queue.out() |> do_grant_from_queue(state, clock)
  end

  defp grant_from_queue(state, _clock), do: {:ok, state, []}

  # Pattern-matched dispatch on the :queue.out/1 result:
  # empty queue → done; value popped → grant and recurse.
  defp do_grant_from_queue({:empty, _}, state, _clock), do: {:ok, state, []}

  defp do_grant_from_queue({{:value, {job_id, requestor_id}}, queue}, state, clock) do
    grant = make_event(clock, requestor_id, {:grant, state.id, job_id})
    state = %{state | queue: queue, busy: state.busy + 1, grants: state.grants + 1}
    # Recurse: capacity may allow more grants
    {:ok, state, more_grants} = grant_from_queue(state, clock)
    {:ok, state, [grant | more_grants]}
  end

  # ============================================================
  # Private: grant from queue (preemptive — :gb_trees)
  # ============================================================

  defp grant_from_queue_preemptive(%{busy: busy, capacity: cap} = state, clock) when busy < cap do
    state.queue |> :gb_trees.is_empty() |> do_grant_preemptive(state, clock)
  end

  defp grant_from_queue_preemptive(state, _clock), do: {:ok, state, []}

  # Pattern-matched dispatch on the gb_trees emptiness check:
  # empty → done; non-empty → take smallest and recurse.
  defp do_grant_preemptive(true, state, _clock), do: {:ok, state, []}

  defp do_grant_preemptive(false, state, clock) do
    {{priority, _seq}, {job_id, requestor_id, _remaining}, queue} =
      :gb_trees.take_smallest(state.queue)

    grant = make_event(clock, requestor_id, {:grant, state.id, job_id})
    holders = Map.put(state.holders, job_id, {requestor_id, priority, clock_to_number(clock)})

    state = %{
      state
      | queue: queue,
        busy: state.busy + 1,
        grants: state.grants + 1,
        holders: holders
    }

    {:ok, state, more_grants} = grant_from_queue_preemptive(state, clock)
    {:ok, state, [grant | more_grants]}
  end

  # --- Private: schedule capacity ---

  defp maybe_update_capacity(%{schedule: nil} = state, _clock), do: state

  defp maybe_update_capacity(%{schedule: schedule} = state, clock) do
    new_cap = schedule_capacity(schedule, clock_to_number(clock))
    apply_capacity_change(new_cap, state.capacity, state, clock)
  end

  # Same-position binding: if new_cap equals old_cap, this clause matches
  # (both get bound to `cap`) and the state passes through unchanged.
  defp apply_capacity_change(cap, cap, state, _clock), do: state

  defp apply_capacity_change(new_cap, _old_cap, state, clock) do
    %{state | capacity: new_cap, last_capacity_check: clock_to_number(clock)}
  end

  defp schedule_capacity(schedule, t) do
    t_int = trunc(t)
    find_in_schedule(schedule, t_int) |> resolve_schedule_hit(schedule, t_int)
  end

  # Pattern-matched dispatch: if the direct lookup hit, return it;
  # otherwise fall through to the wrap-around search.
  defp resolve_schedule_hit({:ok, cap}, _schedule, _t_int), do: cap

  defp resolve_schedule_hit(:not_found, schedule, t_int),
    do: schedule_capacity_wrapped(schedule, t_int)

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
    find_in_schedule(schedule, rem(t_int, total)) |> resolve_mod_hit(schedule)
  end

  # Pattern-matched dispatch for the mod-wrapped search: hit returns the cap;
  # miss falls back to the first schedule entry (graceful degradation).
  defp resolve_mod_hit({:ok, cap}, _schedule), do: cap
  defp resolve_mod_hit(:not_found, schedule), do: elem(hd(schedule), 1)

  # --- Private: clock format dispatch ---

  defp clock_to_number({tick, _diasca}), do: tick * 1.0
  defp clock_to_number(clock) when is_number(clock), do: clock * 1.0

  defp make_event({_tick, _diasca}, target, payload), do: {:same_tick, target, payload}
  defp make_event(clock, target, payload) when is_float(clock), do: {clock, target, payload}
end
