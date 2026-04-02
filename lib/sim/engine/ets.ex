defmodule Sim.Engine.ETS do
  @moduledoc """
  ETS-backed simulation engine — O(1) entity lookup and in-place update.

  Same tight-loop architecture as `Sim.Engine`, but entity states live
  in an ETS table instead of a Map. This eliminates the two costs that
  dominate at 10K+ entities:

  - `Map.fetch!` — O(log32 N) HAMT traversal → `:ets.lookup_element` O(1)
  - `Map.put` — path-copy creating garbage → `:ets.insert` in-place mutation

  The calendar remains `:gb_trees` (not the bottleneck — proven by the
  calendar pressure benchmark).

  ## When to use

  - 10K+ entities: ETS engine is 2-4x faster than Map engine
  - <1K entities: Map engine is slightly faster (no ETS overhead)
  - `Sim.run(mode: :ets)` to select this engine
  """

  defstruct [
    :entity_table,
    :module_table,
    calendar: :gb_trees.empty(),
    seq: 0,
    clock: 0.0,
    stop_time: :infinity,
    events_processed: 0
  ]

  @doc """
  Run a simulation with ETS-backed entity storage.
  Same options as `Sim.Engine.run/1`.
  """
  def run(opts) do
    entities_spec = Keyword.fetch!(opts, :entities)
    initial_events = Keyword.fetch!(opts, :initial_events)
    stop_time = Keyword.get(opts, :stop_time, :infinity)

    # ETS tables: {id, state} and {id, module}
    entity_table = :ets.new(:sim_entities, [:set, :public])
    module_table = :ets.new(:sim_modules, [:set, :public, read_concurrency: true])

    # Initialize entities directly into ETS
    Enum.each(entities_spec, fn {id, module, config} ->
      {:ok, state} = module.init(config)
      :ets.insert(entity_table, {id, state})
      :ets.insert(module_table, {id, module})
    end)

    # Build calendar
    {calendar, seq} =
      Enum.reduce(initial_events, {:gb_trees.empty(), 0}, fn {time, target, event}, {tree, seq} ->
        {:gb_trees.insert({time, seq}, {target, event}, tree), seq + 1}
      end)

    engine = %__MODULE__{
      entity_table: entity_table,
      module_table: module_table,
      calendar: calendar,
      seq: seq,
      stop_time: stop_time
    }

    # Run
    engine = loop(engine)

    # Collect statistics
    stats =
      :ets.foldl(
        fn {id, entity_state}, acc ->
          [{^id, module}] = :ets.lookup(module_table, id)

          if function_exported?(module, :statistics, 1) do
            Map.put(acc, id, module.statistics(entity_state))
          else
            acc
          end
        end,
        %{},
        entity_table
      )

    # Cleanup
    :ets.delete(entity_table)
    :ets.delete(module_table)

    {:ok, %{
      clock: engine.clock,
      events: engine.events_processed,
      stats: stats
    }}
  end

  # --- Tight loop: ETS lookup/insert instead of Map fetch/put ---

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
          # O(1) lookups — the whole point
          module = :ets.lookup_element(engine.module_table, target, 2)
          entity_state = :ets.lookup_element(engine.entity_table, target, 2)

          {:ok, new_state, new_events} =
            module.handle_event(event, time, entity_state)

          # O(1) in-place update — no HAMT copy, no garbage
          :ets.insert(engine.entity_table, {target, new_state})

          # Insert new events into calendar
          {calendar, seq} = insert_events(calendar, engine.seq, new_events)

          %{engine |
            calendar: calendar,
            seq: seq,
            clock: time,
            events_processed: engine.events_processed + 1
          }
          |> loop()
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
