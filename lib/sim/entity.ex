defmodule Sim.Entity do
  @moduledoc """
  Behaviour for simulation entities.

  Each entity runs as a process managed by `Sim.EntityManager`.
  Entities receive events from the calendar and return new events
  to schedule. State is immutable between events.

  ## Example

      defmodule Machine do
        @behaviour Sim.Entity

        @impl true
        def init(config) do
          {:ok, %{id: config.id, status: :idle, queue: :queue.new(),
                  busy_time: 0.0, jobs: 0}}
        end

        @impl true
        def handle_event({:arrive, job}, clock, state) do
          case state.status do
            :idle ->
              service = Sim.Random.exponential(state, :service)
              events = [{clock + service, state.id, {:depart, job}}]
              {:ok, %{state | status: :busy}, events}
            :busy ->
              {:ok, %{state | queue: :queue.in(job, state.queue)}, []}
          end
        end

        @impl true
        def statistics(state) do
          %{busy_time: state.busy_time, jobs_completed: state.jobs}
        end
      end
  """

  @type event :: term()
  @type clock :: float()
  @type entity_id :: term()
  @type scheduled_event :: {clock(), entity_id(), event()}

  @doc "Initialize entity state from config."
  @callback init(config :: map()) :: {:ok, state :: term()}

  @doc """
  Handle a simulation event at the given clock time.
  Returns updated state and a list of new events to schedule.
  Each event is `{time, target_entity_id, event_payload}`.
  """
  @callback handle_event(event :: event(), clock :: clock(), state :: term()) ::
              {:ok, new_state :: term(), events :: [scheduled_event()]}

  @doc "Return statistics map for output analysis."
  @callback statistics(state :: term()) :: map()

  @optional_callbacks [statistics: 1]
end
