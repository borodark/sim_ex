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
  """

  defmacro __using__(_opts) do
    quote do
      import Sim.DSL, only: [model: 2, exponential: 1, uniform: 2, constant: 1]

      Module.register_attribute(__MODULE__, :sim_resources, accumulate: true)
      Module.register_attribute(__MODULE__, :sim_processes, accumulate: true)
      Module.put_attribute(__MODULE__, :sim_model_name, nil)

      @before_compile Sim.DSL
    end
  end

  defmacro model(name, do: block) do
    quote do
      @sim_model_name unquote(name)
      import Sim.DSL, only: [resource: 2, process: 2, exponential: 1, uniform: 2, constant: 1]
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

  # --- AST Parsing ---

  defp parse_steps({:__block__, _, statements}) do
    Enum.map(statements, &parse_step/1)
  end

  defp parse_steps(single) do
    [parse_step(single)]
  end

  defp parse_step({:arrive, _, [opts]}) when is_list(opts) do
    {:arrive, Enum.map(opts, fn {k, v} -> {k, eval_dist(v)} end)}
  end

  defp parse_step({:seize, _, [name]}), do: {:seize, name}
  defp parse_step({:hold, _, [dist]}), do: {:hold, eval_dist(dist)}
  defp parse_step({:release, _, [name]}), do: {:release, name}
  defp parse_step({:depart, _, _}), do: {:depart, []}

  # Evaluate distribution constructor AST at compile time
  defp eval_dist({:exponential, _, [mean]}), do: {:exponential, mean}
  defp eval_dist({:uniform, _, [a, b]}), do: {:uniform, {a, b}}
  defp eval_dist({:constant, _, [val]}), do: {:constant, val}
  defp eval_dist(other), do: other

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
        initial_events = unquote(build_initial_events(processes))

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
        quote do
          {unquote(name), Sim.DSL.Resource,
           %{
             id: unquote(name),
             capacity: unquote(opts[:capacity] || 1),
             service: unquote(Macro.escape(opts[:service] || {:constant, 0})),
             seed: seed + :erlang.phash2(unquote(name))
           }}
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

  defp build_initial_events(processes) do
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
      {:arrive, opts} -> Keyword.get(opts, :every, {:exponential, 1.0})
      nil -> {:exponential, 1.0}
    end
  end
end
