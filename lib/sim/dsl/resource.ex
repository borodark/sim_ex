defmodule Sim.DSL.Resource do
  @moduledoc """
  Resource entity for the DSL seize/release protocol.

  Unlike `Sim.Resource` (which uses arrive/depart), this entity
  implements a request/grant pattern for process-flow DSL models:

  - `{:seize_request, job_id, requestor_id}` — request capacity
  - `{:release, job_id}` — release capacity

  When capacity is available, immediately sends `{:grant, resource_name, job_id}`
  back to the requestor. Otherwise queues the request.
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
    grants: 0,
    releases: 0
  ]

  @impl true
  def init(config) do
    seed = config[:seed] || :erlang.phash2(config.id)

    {:ok,
     %__MODULE__{
       id: config.id,
       capacity: config[:capacity] || 1,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  @impl true
  def handle_event({:seize_request, job_id, requestor_id}, clock, state) do
    if state.busy < state.capacity do
      grant_event = make_event(clock, requestor_id, {:grant, state.id, job_id})
      state = %{state | busy: state.busy + 1, grants: state.grants + 1}
      {:ok, state, [grant_event]}
    else
      state = %{state | queue: :queue.in({job_id, requestor_id}, state.queue)}
      {:ok, state, []}
    end
  end

  def handle_event({:release, _job_id}, clock, state) do
    state = %{state | releases: state.releases + 1}

    case :queue.out(state.queue) do
      {{:value, {next_job_id, next_requestor_id}}, queue} ->
        grant_event = make_event(clock, next_requestor_id, {:grant, state.id, next_job_id})
        state = %{state | queue: queue, grants: state.grants + 1}
        {:ok, state, [grant_event]}

      {:empty, _} ->
        {:ok, %{state | busy: state.busy - 1}, []}
    end
  end

  @impl true
  def statistics(state) do
    %{
      grants: state.grants,
      releases: state.releases,
      queue_length: :queue.len(state.queue)
    }
  end

  # --- Private ---

  defp make_event({_tick, _diasca}, target, payload) do
    {:same_tick, target, payload}
  end

  defp make_event(clock, target, payload) when is_float(clock) do
    {clock, target, payload}
  end
end
