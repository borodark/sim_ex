defmodule Sim.Clock do
  @moduledoc """
  Virtual simulation clock with barrier synchronization.

  Advances time discretely from event to event (next-event time advance).
  The clock never runs ahead of entity processing — entities must complete
  the current event before the clock advances to the next.

  Inspired by Sim-Diasca's tick model but simplified: no diascas,
  just strict event ordering by timestamp with FIFO tie-breaking.
  """

  use GenServer

  defstruct [
    :calendar,
    :entities,
    :topology,
    :stats,
    :stop_time,
    :seed,
    clock: 0.0,
    events_processed: 0,
    status: :idle
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Current virtual time."
  def now(server \\ __MODULE__) do
    GenServer.call(server, :now)
  end

  @doc "Total events processed."
  def events_processed(server \\ __MODULE__) do
    GenServer.call(server, :events_processed)
  end

  @doc "Run simulation until stop_time or event exhaustion."
  def run(server \\ __MODULE__) do
    GenServer.call(server, :run, :infinity)
  end

  @doc "Advance one event (for debugging / stepping)."
  def step(server \\ __MODULE__) do
    GenServer.call(server, :step)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      calendar: opts[:calendar] || raise("calendar required"),
      entities: opts[:entities] || raise("entities required"),
      topology: opts[:topology],
      stats: opts[:stats],
      stop_time: opts[:stop_time] || :infinity,
      seed: opts[:seed]
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:now, _from, state) do
    {:reply, state.clock, state}
  end

  def handle_call(:events_processed, _from, state) do
    {:reply, state.events_processed, state}
  end

  def handle_call(:run, _from, state) do
    state = run_loop(state)
    {:reply, {:ok, state.clock, state.events_processed}, state}
  end

  def handle_call(:step, _from, state) do
    case advance_one(state) do
      {:ok, state} -> {:reply, {:ok, state.clock}, state}
      :empty -> {:reply, :empty, state}
      :stopped -> {:reply, :stopped, state}
    end
  end

  # --- Simulation loop ---

  defp run_loop(state) do
    case advance_one(state) do
      {:ok, state} -> run_loop(state)
      :empty -> %{state | status: :done}
      :stopped -> %{state | status: :done}
    end
  end

  defp advance_one(state) do
    case Sim.Calendar.pop(state.calendar) do
      {:ok, {time, target, event}} ->
        if time > state.stop_time do
          :stopped
        else
          new_events = dispatch_event(state.entities, target, event, time)

          Enum.each(new_events, fn {t, tgt, evt} ->
            Sim.Calendar.push(state.calendar, t, tgt, evt)
          end)

          if state.stats do
            Sim.Statistics.record(state.stats, :event, time)
          end

          {:ok, %{state | clock: time, events_processed: state.events_processed + 1}}
        end

      :empty ->
        :empty
    end
  end

  defp dispatch_event(entities, target, event, time) do
    Sim.EntityManager.dispatch(entities, target, event, time)
  end
end
