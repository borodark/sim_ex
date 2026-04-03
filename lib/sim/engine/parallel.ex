defmodule Sim.Engine.Parallel do
  @moduledoc """
  Parallel diasca engine — uses all available BEAM schedulers.

  Tick-diasca guarantees that all events at `(T, D)` are causally
  independent (produced at `(T, D-1)`). If they target different
  entities, they can execute in parallel. This engine exploits that:

  1. Drain all events at current `{tick, diasca}` from the calendar
  2. Partition by target entity into N worker batches
  3. Send batches to pre-spawned persistent workers (no spawn overhead)
  4. Each worker: ETS lookup → handle_event → ETS insert → return new events
  5. Coordinator: merge new events into calendar, advance diasca or tick

  Entity states live in ETS (shared, O(1) access from any process).
  The calendar stays centralized (not the bottleneck).

  Workers are spawned once at init and reused across all diascas.
  This eliminates ~50µs spawn overhead per diasca that killed
  `Task.async_stream` on thin diascas.

  ## Options

  - `:workers` — number of parallel workers (default: `System.schedulers_online()`)
  - `:parallel_threshold` — minimum events per diasca to parallelize (default: 128)

  ## Usage

      Sim.run(mode: :parallel, entities: [...], initial_events: [...],
        stop_tick: 10_000, workers: 16)
  """

  @default_threshold 128

  defstruct [
    :entity_table,
    :module_table,
    :worker_pids,
    :workers,
    :threshold,
    calendar: :gb_trees.empty(),
    seq: 0,
    tick: 0,
    diasca: 0,
    stop_tick: :infinity,
    events_processed: 0
  ]

  def run(opts) do
    entities_spec = Keyword.fetch!(opts, :entities)
    initial_events = Keyword.fetch!(opts, :initial_events)
    stop_tick = Keyword.get(opts, :stop_tick, :infinity)
    workers = Keyword.get(opts, :workers, System.schedulers_online())
    threshold = Keyword.get(opts, :parallel_threshold, @default_threshold)

    # ETS tables — shared across workers
    entity_table = :ets.new(:par_entities, [:set, :public, write_concurrency: true])
    module_table = :ets.new(:par_modules, [:set, :public, read_concurrency: true])

    Enum.each(entities_spec, fn {id, module, config} ->
      {:ok, state} = module.init(config)
      :ets.insert(entity_table, {id, state})
      :ets.insert(module_table, {id, module})
    end)

    {calendar, seq} =
      Enum.reduce(initial_events, {:gb_trees.empty(), 0}, fn {tick, target, event}, {tree, seq} ->
        {:gb_trees.insert({tick, 0, seq}, {target, event}, tree), seq + 1}
      end)

    # Spawn persistent worker pool
    coordinator = self()

    worker_pids =
      for _i <- 1..workers do
        spawn_link(fn -> worker_loop(coordinator, entity_table, module_table) end)
      end

    engine = %__MODULE__{
      entity_table: entity_table,
      module_table: module_table,
      worker_pids: worker_pids,
      calendar: calendar,
      seq: seq,
      stop_tick: stop_tick,
      workers: workers,
      threshold: threshold
    }

    engine = loop(engine)

    # Stop workers
    Enum.each(worker_pids, fn pid -> send(pid, :stop) end)

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

    :ets.delete(entity_table)
    :ets.delete(module_table)

    {:ok,
     %{
       tick: engine.tick,
       diasca: engine.diasca,
       events: engine.events_processed,
       stats: stats
     }}
  end

  # --- Persistent worker process ---

  defp worker_loop(coordinator, entity_table, module_table) do
    receive do
      {:work, ref, events, tick, diasca} ->
        new_events = process_batch(events, entity_table, module_table, tick, diasca)
        send(coordinator, {:done, ref, new_events})
        worker_loop(coordinator, entity_table, module_table)

      :stop ->
        :ok
    end
  end

  defp process_batch(events, entity_table, module_table, tick, diasca) do
    Enum.flat_map(events, fn {target, event} ->
      module = :ets.lookup_element(module_table, target, 2)
      state = :ets.lookup_element(entity_table, target, 2)

      {:ok, new_state, new_events} =
        module.handle_event(event, {tick, diasca}, state)

      :ets.insert(entity_table, {target, new_state})
      new_events
    end)
  end

  # --- Main loop: drain diasca → dispatch → merge → repeat ---

  defp loop(engine) do
    case :gb_trees.is_empty(engine.calendar) do
      true ->
        engine

      false ->
        {{tick, diasca, _seq}, _val} = :gb_trees.smallest(engine.calendar)

        if tick > engine.stop_tick do
          engine
        else
          {events, calendar} = drain_diasca(engine.calendar, tick, diasca)
          count = length(events)

          new_events =
            if count >= engine.threshold do
              dispatch_parallel(events, engine, tick, diasca)
            else
              dispatch_sequential(events, engine, tick, diasca)
            end

          {calendar, seq} = insert_diasca_events(calendar, engine.seq, tick, diasca, new_events)

          %{
            engine
            | calendar: calendar,
              seq: seq,
              tick: tick,
              diasca: diasca,
              events_processed: engine.events_processed + count
          }
          |> loop()
        end
    end
  end

  # --- Drain all events at {tick, diasca} ---

  defp drain_diasca(calendar, tick, diasca) do
    drain_diasca(calendar, tick, diasca, [])
  end

  defp drain_diasca(calendar, tick, diasca, acc) do
    case :gb_trees.is_empty(calendar) do
      true ->
        {acc, calendar}

      false ->
        {{t, d, _seq}, _val} = :gb_trees.smallest(calendar)

        if t == tick and d == diasca do
          {_key, {target, event}, calendar} = :gb_trees.take_smallest(calendar)
          drain_diasca(calendar, tick, diasca, [{target, event} | acc])
        else
          {acc, calendar}
        end
    end
  end

  # --- Parallel dispatch via persistent worker pool ---

  defp dispatch_parallel(events, engine, tick, diasca) do
    # Partition events into worker buckets by entity hash
    n = engine.workers
    buckets = partition_events(events, n)

    # Send work to each worker that has events
    refs =
      buckets
      |> Enum.with_index()
      |> Enum.flat_map(fn {batch, idx} ->
        if batch == [] do
          []
        else
          ref = make_ref()
          pid = Enum.at(engine.worker_pids, idx)
          send(pid, {:work, ref, batch, tick, diasca})
          [ref]
        end
      end)

    # Collect results — one message per active worker
    collect_results(refs, [])
  end

  defp collect_results([], acc), do: acc

  defp collect_results(refs, acc) do
    receive do
      {:done, ref, new_events} ->
        remaining = List.delete(refs, ref)
        collect_results(remaining, new_events ++ acc)
    end
  end

  # Partition events into N buckets by target hash — deterministic
  defp partition_events(events, n) do
    empty = List.duplicate([], n)

    events
    |> Enum.reduce(empty, fn {target, _event} = e, buckets ->
      idx = rem(:erlang.phash2(target), n)
      List.update_at(buckets, idx, fn b -> [e | b] end)
    end)
  end

  # --- Sequential dispatch (below threshold) ---

  defp dispatch_sequential(events, engine, tick, diasca) do
    process_batch(events, engine.entity_table, engine.module_table, tick, diasca)
  end

  # --- Event insertion with diasca stamping ---

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
