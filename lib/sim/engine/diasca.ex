defmodule Sim.Engine.Diasca do
  @moduledoc """
  Tick-diasca simulation engine — causal ordering via two-level timestamps.

  Based on Sim-Diasca's synchronization model (EDF, 2010). Events use
  `{tick, diasca}` timestamps instead of floats. When entity A handles
  an event at `(T, D)` and produces events, those events are stamped:

  - `{:same_tick, target, payload}` → `(T, D+1)` — causal reaction
  - `{:tick, future_tick, target, payload}` → `(future_tick, 0)` — scheduled
  - `{:delay, delta, target, payload}` → `(T + delta, 0)` — relative

  Tick advances only when no more diascas are pending (quiescence).
  This is automatic: `{T, D+1, *}` sorts before `{T+1, 0, *}` in
  `:gb_trees`, so the loop simply pops the smallest key.

  Same tight-loop architecture as `Sim.Engine` — zero message passing.
  """

  defstruct calendar: :gb_trees.empty(),
            entities: %{},
            modules: %{},
            seq: 0,
            tick: 0,
            diasca: 0,
            stop_tick: :infinity,
            events_processed: 0

  @doc """
  Run a tick-diasca simulation to completion.

  ## Options

  - `:entities` — list of `{id, module, config}`
  - `:initial_events` — list of `{tick, target, event}` (tick is integer)
  - `:stop_tick` — integer tick to stop at (default: `:infinity`)
  """
  def run(opts) do
    entities_spec = Keyword.fetch!(opts, :entities)
    initial_events = Keyword.fetch!(opts, :initial_events)
    stop_tick = Keyword.get(opts, :stop_tick, :infinity)

    # Initialize entity states
    {entities, modules} =
      Enum.reduce(entities_spec, {%{}, %{}}, fn {id, module, config}, {ents, mods} ->
        {:ok, state} = module.init(config)
        {Map.put(ents, id, state), Map.put(mods, id, module)}
      end)

    # Build initial calendar — all initial events at diasca 0
    {calendar, seq} =
      Enum.reduce(initial_events, {:gb_trees.empty(), 0}, fn {tick, target, event}, {tree, seq} ->
        {:gb_trees.insert({tick, 0, seq}, {target, event}, tree), seq + 1}
      end)

    engine = %__MODULE__{
      calendar: calendar,
      entities: entities,
      modules: modules,
      seq: seq,
      stop_tick: stop_tick
    }

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
       tick: engine.tick,
       diasca: engine.diasca,
       events: engine.events_processed,
       stats: stats
     }}
  end

  # --- Tight loop ---

  defp loop(engine) do
    case :gb_trees.is_empty(engine.calendar) do
      true ->
        engine

      false ->
        {{tick, diasca, _seq}, {target, event}, calendar} =
          :gb_trees.take_smallest(engine.calendar)

        if tick > engine.stop_tick do
          engine
        else
          module = Map.fetch!(engine.modules, target)
          entity_state = Map.fetch!(engine.entities, target)

          {:ok, new_state, new_events} =
            module.handle_event(event, {tick, diasca}, entity_state)

          {calendar, seq} =
            insert_diasca_events(calendar, engine.seq, tick, diasca, new_events)

          %{
            engine
            | calendar: calendar,
              entities: Map.put(engine.entities, target, new_state),
              modules: engine.modules,
              seq: seq,
              tick: tick,
              diasca: diasca,
              events_processed: engine.events_processed + 1
          }
          |> loop()
        end
    end
  end

  # --- Event insertion with diasca stamping ---

  @compile {:inline, insert_diasca_events: 5}

  defp insert_diasca_events(calendar, seq, _tick, _diasca, []) do
    {calendar, seq}
  end

  defp insert_diasca_events(calendar, seq, tick, diasca, [{:same_tick, target, event} | rest]) do
    calendar = :gb_trees.insert({tick, diasca + 1, seq}, {target, event}, calendar)
    insert_diasca_events(calendar, seq + 1, tick, diasca, rest)
  end

  defp insert_diasca_events(calendar, seq, tick, diasca, [
         {:tick, future_tick, target, event} | rest
       ])
       when future_tick > tick do
    calendar = :gb_trees.insert({future_tick, 0, seq}, {target, event}, calendar)
    insert_diasca_events(calendar, seq + 1, tick, diasca, rest)
  end

  defp insert_diasca_events(calendar, seq, tick, diasca, [{:delay, delta, target, event} | rest])
       when is_integer(delta) and delta > 0 do
    calendar = :gb_trees.insert({tick + delta, 0, seq}, {target, event}, calendar)
    insert_diasca_events(calendar, seq + 1, tick, diasca, rest)
  end
end
