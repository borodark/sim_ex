defmodule Sim.DSL do
  @moduledoc """
  Macro-based DSL for discrete-event simulation models.

  Compiles GPSS/Arena-style process flows into `Sim.Entity` modules.
  Readable by subject matter experts, executable by sim_ex.

  ## Example

      defmodule Barbershop do
        use Sim.DSL

        model :barbershop do
          resource :barber, capacity: 1

          process :customer do
            arrive every: exponential(18)
            seize :barber
            hold exponential(16)
            release :barber
            depart
          end
        end
      end

      Barbershop.run(stop_time: 10_000.0, seed: 42)

  ## Advanced Example

      defmodule Electronics do
        use Sim.DSL

        model :electronics do
          resource :solder, capacity: 8
          resource :inspector, schedule: [{0..479, 3}, {480..959, 1}]
          resource :rework, capacity: 1

          process :pcb do
            arrive schedule: [{0..479, {:exponential, 3.0}}, {480..959, {:exponential, 6.0}}]
            split 4                          # PCB → 4 panels
            seize :solder
            hold exponential(3.0)
            release :solder
            decide 0.05, :rework_panel       # 5% fail inspection
            combine 4                         # 4 panels → 1 board
            batch 10                          # 10 boards → 1 tray
            depart
            label :rework_panel
            seize :rework
            hold exponential(6.0)
            release :rework
            depart
          end
        end
      end

  ## Verbs

  | Verb | Arena Equivalent | Description |
  |------|-----------------|-------------|
  | `arrive every:` | CREATE | Stationary interarrival |
  | `arrive schedule:` | CREATE (schedule) | Non-stationary arrivals |
  | `seize :resource` | SEIZE | Request capacity |
  | `hold distribution` | DELAY | Consume time |
  | `release :resource` | RELEASE | Free capacity |
  | `route distribution` | ROUTE | Travel delay (no resource) |
  | `decide prob, :label` | DECIDE | Binary probabilistic branch |
  | `decide [{p, :l}, ...]` | DECIDE | Multi-way weighted routing |
  | `batch N` | BATCH | Accumulate N parts |
  | `split N` | SEPARATE | One part → N parts |
  | `combine N` | COMBINE | N parts → one |
  | `label :name` | STATION | Jump target for decide |
  | `depart` | DISPOSE | Exit, collect statistics |
  | `resource :r, capacity: N` | RESOURCE | Fixed capacity |
  | `resource :r, schedule: [...]` | SCHEDULE | Time-varying capacity |
  """

  defmacro __using__(_opts) do
    quote do
      import Sim.DSL, only: [model: 2, exponential: 1, uniform: 2, constant: 1, label: 1]

      Module.register_attribute(__MODULE__, :sim_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :sim_processes, accumulate: true)
      Module.put_attribute(__MODULE__, :sim_model_name, nil)

      @before_compile Sim.DSL
    end
  end

  defmacro model(name, do: block) do
    quote do
      @sim_model_name unquote(name)
      import Sim.DSL,
        only: [resource: 2, process: 2, exponential: 1, uniform: 2, constant: 1, label: 1]

      unquote(block)
    end
  end

  defmacro resource(name, opts) do
    quote do
      @sim_resources {unquote(name), unquote(opts)}
    end
  end

  defmacro process(name, do: block) do
    steps = parse_steps(block)

    quote do
      @sim_processes {unquote(name), unquote(Macro.escape(steps))}
    end
  end

  # Distribution constructors (data, not computation)
  def exponential(mean), do: {:exponential, mean}
  def uniform(a, b), do: {:uniform, {a, b}}
  def constant(value), do: {:constant, value}
  def label(name), do: {:label, name}

  # --- AST Parsing ---

  defp parse_steps({:__block__, _, statements}) do
    Enum.map(statements, &parse_step/1)
  end

  defp parse_steps(single) do
    [parse_step(single)]
  end

  defp parse_step({:arrive, _, [opts]}) when is_list(opts) do
    {:arrive,
     Enum.map(opts, fn
       {:every, v} -> {:every, eval_dist(v)}
       {:schedule, v} -> {:schedule, eval_schedule(v)}
       {k, v} -> {k, eval_dist(v)}
     end)}
  end

  defp parse_step({:seize, _, [name]}), do: {:seize, name}
  defp parse_step({:hold, _, [dist]}), do: {:hold, eval_dist(dist)}
  defp parse_step({:release, _, [name]}), do: {:release, name}
  defp parse_step({:depart, _, _}), do: {:depart, []}

  # decide probability, :label — branch with probability to label, else continue
  defp parse_step({:decide, _, [prob, label_name]})
       when is_number(prob) and is_atom(label_name) do
    {:decide, {prob, label_name}}
  end

  # decide [{0.7, :route_a}, {0.3, :route_b}] — weighted multi-way routing
  defp parse_step({:decide, _, [routes]}) when is_list(routes) do
    {:decide_multi, routes}
  end

  # batch count — accumulate N parts before proceeding
  defp parse_step({:batch, _, [count]}) when is_integer(count) do
    {:batch, count}
  end

  # route distribution — travel delay between stations (hold without resource)
  defp parse_step({:route, _, [dist]}), do: {:route, eval_dist(dist)}

  # split N — one part becomes N parts (kitting, unbundling)
  defp parse_step({:split, _, [count]}) when is_integer(count), do: {:split, count}

  # combine N — N parts merge into 1 (assembly)
  defp parse_step({:combine, _, [count]}) when is_integer(count), do: {:combine, count}

  # label :name — named jump target for decide
  defp parse_step({:label, _, [name]}) when is_atom(name), do: {:label, name}
  defp parse_step({{:label, name}, _, _}) when is_atom(name), do: {:label, name}

  # Evaluate distribution constructor AST at compile time
  defp eval_dist({:exponential, _, [mean]}), do: {:exponential, mean}
  defp eval_dist({:uniform, _, [a, b]}), do: {:uniform, {a, b}}
  defp eval_dist({:constant, _, [val]}), do: {:constant, val}
  defp eval_dist(other), do: other

  # Evaluate schedule: [{range_ast, dist_ast}, ...] → [{Range, {dist, mean}}, ...]
  defp eval_schedule(entries) when is_list(entries) do
    Enum.map(entries, fn
      # {range_ast, dist_tuple} — range may be AST like {:.., _, [0, 299]}
      {{:.., _, [a, b]}, dist} -> {a..b, eval_dist_tuple(dist)}
      {%Range{} = range, dist} -> {range, eval_dist_tuple(dist)}
      # Already evaluated (e.g., {0..299, {:exponential, 10.0}})
      {a..b//_, dist} -> {a..b, eval_dist_tuple(dist)}
      other -> other
    end)
  end

  defp eval_dist_tuple({:exponential, _, [mean]}), do: {:exponential, mean}
  defp eval_dist_tuple({:uniform, _, [a, b]}), do: {:uniform, {a, b}}
  defp eval_dist_tuple({:constant, _, [val]}), do: {:constant, val}
  defp eval_dist_tuple({d, m}), do: {d, m}
  defp eval_dist_tuple(other), do: other

  # --- Code Generation ---

  defmacro __before_compile__(env) do
    resources = Module.get_attribute(env.module, :sim_resources) |> Enum.reverse()
    processes = Module.get_attribute(env.module, :sim_processes) |> Enum.reverse()
    _model_name = Module.get_attribute(env.module, :sim_model_name)

    process_modules =
      Enum.map(processes, fn {name, steps} ->
        Sim.DSL.Process.compile_entity(env.module, name, steps, resources)
      end)

    run_fn = compile_run(env.module, processes, resources)

    quote do
      (unquote_splicing(process_modules))
      unquote(run_fn)
    end
  end

  defp compile_run(host_module, processes, resources) do
    quote do
      def run(opts \\ []) do
        mode = Keyword.get(opts, :mode, :engine)
        seed = Keyword.get(opts, :seed, 42)
        stop_time = Keyword.get(opts, :stop_time, 10_000.0)
        stop_tick = Keyword.get(opts, :stop_tick, 10_000)

        entities = unquote(build_entity_list(host_module, processes, resources))
        initial_events = unquote(build_initial_events(processes, resources))

        sim_opts =
          case mode do
            :diasca ->
              [
                entities: entities,
                initial_events: initial_events,
                stop_tick: stop_tick,
                mode: :diasca
              ]

            _ ->
              [
                entities: entities,
                initial_events: initial_events,
                stop_time: stop_time,
                mode: mode
              ]
          end

        Sim.run(sim_opts)
      end
    end
  end

  defp build_entity_list(host_module, processes, resources) do
    resource_entries =
      Enum.map(resources, fn {name, opts} ->
        schedule = opts[:schedule]

        config =
          if schedule do
            quote do
              %{
                id: unquote(name),
                schedule: unquote(Macro.escape(schedule)),
                seed: seed + :erlang.phash2(unquote(name))
              }
            end
          else
            quote do
              %{
                id: unquote(name),
                capacity: unquote(opts[:capacity] || 1),
                seed: seed + :erlang.phash2(unquote(name))
              }
            end
          end

        quote do
          {unquote(name), Sim.DSL.Resource, unquote(config)}
        end
      end)

    process_entries =
      Enum.flat_map(processes, fn {name, _steps} ->
        source_id = :"#{name}_source"
        process_mod = Module.concat(host_module, Macro.camelize(to_string(name)))

        [
          quote do
            {unquote(source_id), Sim.Source,
             %{
               id: unquote(source_id),
               target: unquote(name),
               interarrival: unquote(Macro.escape(find_arrival_dist(name, processes))),
               seed: seed + :erlang.phash2(unquote(source_id))
             }}
          end,
          quote do
            {unquote(name), unquote(process_mod),
             %{id: unquote(name), mode: mode, seed: seed + :erlang.phash2(unquote(name))}}
          end
        ]
      end)

    quote do
      unquote(resource_entries ++ process_entries)
    end
  end

  defp build_initial_events(processes, _resources) do
    Enum.map(processes, fn {name, _steps} ->
      source_id = :"#{name}_source"

      quote do
        case mode do
          :diasca -> {0, unquote(source_id), :generate}
          _ -> {0.0, unquote(source_id), :generate}
        end
      end
    end)
  end

  defp find_arrival_dist(name, processes) do
    {^name, steps} = Enum.find(processes, fn {n, _} -> n == name end)

    case Enum.find(steps, fn {verb, _} -> verb == :arrive end) do
      {:arrive, opts} ->
        cond do
          Keyword.has_key?(opts, :schedule) -> {:scheduled, Keyword.get(opts, :schedule)}
          true -> Keyword.get(opts, :every, {:exponential, 1.0})
        end

      nil ->
        {:exponential, 1.0}
    end
  end
end
