defmodule Sim.Engine do
  @moduledoc """
  Tight-loop simulation engine — zero message passing in the hot path.

  Runs the entire event loop in a single process using plain Elixir
  data structures: `:gb_trees` for the calendar, `Map` for entity
  states. No GenServer calls, no mailbox overhead, no term copying.

  This is 10-100x faster than the GenServer-based `Sim.Clock` +
  `Sim.Calendar` + `Sim.EntityManager` stack for single-node runs.
  The GenServer stack remains available for interactive stepping,
  distributed simulation, and fault-tolerant entity management.

  ## Internal representation

  State is a plain struct passed through a tail-recursive loop:

      %Engine{
        calendar: :gb_trees.tree(),   # {time, seq} => {target, event}
        entities: %{id => entity_state},
        modules:  %{id => module},
        seq: integer(),               # tie-breaking counter
        clock: float(),
        stop_time: float(),
        events_processed: integer()
      }
  """

  defstruct calendar: :gb_trees.empty(),
            entities: %{},
            modules: %{},
            seq: 0,
            clock: 0.0,
            stop_time: :infinity,
            events_processed: 0

  @doc """
  Run a simulation to completion. Returns result map.

  ## Options

  Same as `Sim.run/1`:
  - `:entities` — list of `{id, module, config}`
  - `:initial_events` — list of `{time, target, event}`
  - `:stop_time` — virtual time limit
  """
  def run(opts) do
    {:ok, engine} = init(opts)

    # Run the tight loop
    engine = loop(engine)

    # Collect statistics
    stats =
      Enum.reduce(engine.entities, %{}, fn {id, entity_state}, acc ->
        module = Map.fetch!(engine.modules, id)

        if function_exported?(module, :statistics, 1) do
          Map.put(acc, id, module.statistics(entity_state))
        else
          acc
        end
      end)

    {:ok,
     %{
       clock: engine.clock,
       events: engine.events_processed,
       stats: stats
     }}
  end

  @doc """
  Execute a single event loop iteration. Returns `{:ok, engine}`,
  `{:done, engine}` (calendar empty), or `{:stopped, engine}` (past stop_time).

  Used by `proper_statem` for stateful property testing.
  Production code uses `loop/1` which calls this in a tight loop.
  """
  def step(engine) do
    case :gb_trees.is_empty(engine.calendar) do
      true ->
        {:done, engine}

      false ->
        {{time, _seq}, {target, event}, calendar} =
          :gb_trees.take_smallest(engine.calendar)

        if time > engine.stop_time do
          {:stopped, engine}
        else
          module = Map.fetch!(engine.modules, target)
          entity_state = Map.fetch!(engine.entities, target)

          {:ok, new_entity_state, new_events} =
            module.handle_event(event, time, entity_state)

          {calendar, seq} = insert_events(calendar, engine.seq, new_events)

          engine = %{
            engine
            | calendar: calendar,
              entities: Map.put(engine.entities, target, new_entity_state),
              seq: seq,
              clock: time,
              events_processed: engine.events_processed + 1
          }

          {:ok, engine}
        end
    end
  end

  @doc """
  Initialize an engine struct from opts without running it.
  Returns `{:ok, engine}`.
  """
  def init(opts) do
    entities_spec = Keyword.fetch!(opts, :entities)
    initial_events = Keyword.fetch!(opts, :initial_events)
    stop_time = Keyword.get(opts, :stop_time, :infinity)

    {entities, modules} =
      Enum.reduce(entities_spec, {%{}, %{}}, fn {id, module, config}, {ents, mods} ->
        {:ok, state} = module.init(config)
        {Map.put(ents, id, state), Map.put(mods, id, module)}
      end)

    {calendar, seq} =
      Enum.reduce(initial_events, {:gb_trees.empty(), 0}, fn {time, target, event}, {tree, seq} ->
        {:gb_trees.insert({time, seq}, {target, event}, tree), seq + 1}
      end)

    {:ok,
     %__MODULE__{
       calendar: calendar,
       entities: entities,
       modules: modules,
       seq: seq,
       stop_time: stop_time
     }}
  end

  # --- Tight loop: no GenServer, no message passing ---

  defp loop(engine) do
    case :gb_trees.is_empty(engine.calendar) do
      true ->
        engine

      false ->
        {{time, _seq}, {target, event}, calendar} =
          :gb_trees.take_smallest(engine.calendar)

        if time > engine.stop_time do
          engine
        else
          # Dispatch directly — no GenServer call
          module = Map.fetch!(engine.modules, target)
          entity_state = Map.fetch!(engine.entities, target)

          {:ok, new_entity_state, new_events} =
            module.handle_event(event, time, entity_state)

          # Insert new events directly into tree
          {calendar, seq} =
            insert_events(calendar, engine.seq, new_events)

          engine = %{
            engine
            | calendar: calendar,
              entities: Map.put(engine.entities, target, new_entity_state),
              seq: seq,
              clock: time,
              events_processed: engine.events_processed + 1
          }

          loop(engine)
        end
    end
  end

  @compile {:inline, insert_events: 3}
  defp insert_events(calendar, seq, []) do
    {calendar, seq}
  end

  defp insert_events(calendar, seq, [{time, target, event} | rest]) do
    calendar = :gb_trees.insert({time, seq}, {target, event}, calendar)
    insert_events(calendar, seq + 1, rest)
  end
end
