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

  def handle_call(:step, _from, state), do: state |> advance_one() |> reply_step()

  defp reply_step({:ok, state}), do: {:reply, {:ok, state.clock}, state}
  defp reply_step({:empty, state}), do: {:reply, :empty, state}
  defp reply_step({:stopped, state}), do: {:reply, :stopped, state}

  # --- Simulation loop ---

  defp run_loop(state), do: state |> advance_one() |> continue_loop()

  defp continue_loop({:ok, state}), do: run_loop(state)
  defp continue_loop({:empty, state}), do: %{state | status: :done}
  defp continue_loop({:stopped, state}), do: %{state | status: :done}

  defp advance_one(state) do
    state.calendar
    |> Sim.Calendar.pop()
    |> handle_pop(state)
  end

  defp handle_pop(:empty, state), do: {:empty, state}

  defp handle_pop({:ok, {time, _target, _event}}, %{stop_time: stop_time} = state)
       when time > stop_time,
       do: {:stopped, state}

  defp handle_pop({:ok, {time, target, event}}, state) do
    state.entities
    |> Sim.EntityManager.dispatch(target, event, time)
    |> Enum.each(fn {t, tgt, evt} ->
      Sim.Calendar.push(state.calendar, t, tgt, evt)
    end)

    record_stats(state.stats, time)

    {:ok, %{state | clock: time, events_processed: state.events_processed + 1}}
  end

  defp record_stats(nil, _time), do: :ok
  defp record_stats(stats, time), do: Sim.Statistics.record(stats, :event, time)
end
