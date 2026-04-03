defmodule Sim.DSL.Process do
  @moduledoc """
  Compiles DSL process steps into a `Sim.Entity` module.

  Generates a pool entity that manages multiple concurrent process
  instances. Each instance tracks its step in the flow.

  ## Supported Verbs

  - `seize` / `release` — request and release resources
  - `hold` — consume time (with resource)
  - `route` — travel delay (hold without resource)
  - `decide` — probabilistic branch (binary or multi-way)
  - `batch` — accumulate N instances before proceeding
  - `split` — one instance becomes N (kitting, unbundling)
  - `combine` — N instances merge into one (assembly)
  - `label` — jump target for decide branches
  - `depart` — exit and contribute to statistics
  """

  @doc """
  Generate AST for an Entity module implementing the process flow.
  """
  def compile_entity(host_module, process_name, steps, _resources) do
    module_name = Module.concat(host_module, Macro.camelize(to_string(process_name)))

    # Extract the flow steps (skip :arrive, which is handled by Source)
    flow_steps =
      steps
      |> Enum.reject(fn {verb, _} -> verb == :arrive end)
      |> Enum.with_index()

    quote do
      defmodule unquote(module_name) do
        @behaviour Sim.Entity

        defstruct [
          :id,
          :mode,
          :rand_state,
          instances: %{},
          batch_buffer: %{},
          next_job_id: 1,
          completed: 0,
          total_wait: 0.0,
          total_hold: 0.0
        ]

        @impl true
        def init(config) do
          seed = config[:seed] || :erlang.phash2(config[:id])

          {:ok,
           %__MODULE__{
             id: config.id,
             mode: config[:mode] || :engine,
             rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
           }}
        end

        @impl true
        def handle_event({:arrive, job_id, arrival_time}, clock, state) do
          # New process instance — start at step 0
          instance = %{
            step: 0,
            arrival_time: clock_to_float(clock, arrival_time),
            hold_start: nil
          }

          state = %{state | instances: Map.put(state.instances, job_id, instance)}
          advance_step(job_id, clock, state)
        end

        def handle_event({:grant, _resource_name, job_id}, clock, state) do
          case Map.get(state.instances, job_id) do
            nil ->
              {:ok, state, []}

            instance ->
              # Resource granted — record wait, advance to next step
              wait = clock_to_float(clock, 0) - instance.arrival_time
              instance = %{instance | step: instance.step + 1}

              state = %{
                state
                | instances: Map.put(state.instances, job_id, instance),
                  total_wait: state.total_wait + max(wait, 0.0)
              }

              advance_step(job_id, clock, state)
          end
        end

        def handle_event({:hold_complete, job_id}, clock, state) do
          case Map.get(state.instances, job_id) do
            nil ->
              {:ok, state, []}

            instance ->
              hold_duration = clock_to_float(clock, 0) - (instance.hold_start || 0.0)
              instance = %{instance | step: instance.step + 1}

              state = %{
                state
                | instances: Map.put(state.instances, job_id, instance),
                  total_hold: state.total_hold + hold_duration
              }

              advance_step(job_id, clock, state)
          end
        end

        @impl true
        def statistics(state) do
          n = state.completed

          %{
            completed: n,
            in_progress: map_size(state.instances),
            mean_wait: if(n > 0, do: state.total_wait / n, else: 0.0),
            mean_hold: if(n > 0, do: state.total_hold / n, else: 0.0)
          }
        end

        # --- Step advancement ---

        defp advance_step(job_id, clock, state) do
          instance = Map.fetch!(state.instances, job_id)
          flow = unquote(Macro.escape(flow_steps))

          case Enum.find(flow, fn {_step, idx} -> idx == instance.step end) do
            nil ->
              # Past last step — depart
              state = %{
                state
                | instances: Map.delete(state.instances, job_id),
                  completed: state.completed + 1
              }

              {:ok, state, []}

            {{:seize, resource_name}, _idx} ->
              event =
                make_event(clock, state.mode, resource_name, {:seize_request, job_id, state.id})

              {:ok, state, [event]}

            {{:release, resource_name}, _idx} ->
              event = make_event(clock, state.mode, resource_name, {:release, job_id})
              instance = %{instance | step: instance.step + 1}
              state = %{state | instances: Map.put(state.instances, job_id, instance)}
              # After release, continue to next step
              {_, state, more_events} = advance_step(job_id, clock, state)
              {:ok, state, [event | more_events]}

            {{:hold, dist}, _idx} ->
              {duration, rand_state} = sample_dist(dist, state.rand_state)
              instance = %{instance | hold_start: clock_to_float(clock, 0)}

              state = %{
                state
                | instances: Map.put(state.instances, job_id, instance),
                  rand_state: rand_state
              }

              handle_hold(job_id, duration, clock, state)

            {{:depart, _}, _idx} ->
              state = %{
                state
                | instances: Map.delete(state.instances, job_id),
                  completed: state.completed + 1
              }

              {:ok, state, []}

            {{:decide, {prob, label_name}}, _idx} ->
              {u, rand_state} = :rand.uniform_s(state.rand_state)
              state = %{state | rand_state: rand_state}

              if u < prob do
                # Jump to label
                label_idx = find_label(flow, label_name)
                instance = %{instance | step: label_idx}
                state = %{state | instances: Map.put(state.instances, job_id, instance)}
                advance_step(job_id, clock, state)
              else
                # Continue to next step
                instance = %{instance | step: instance.step + 1}
                state = %{state | instances: Map.put(state.instances, job_id, instance)}
                advance_step(job_id, clock, state)
              end

            {{:decide_multi, routes}, _idx} ->
              {u, rand_state} = :rand.uniform_s(state.rand_state)
              state = %{state | rand_state: rand_state}

              # Find which route: accumulate probabilities until u < cumulative
              {target_label, _} =
                Enum.reduce_while(routes, {nil, 0.0}, fn {prob, label_name}, {_, cum} ->
                  new_cum = cum + prob

                  if u < new_cum,
                    do: {:halt, {label_name, new_cum}},
                    else: {:cont, {label_name, new_cum}}
                end)

              label_idx = find_label(flow, target_label)
              instance = %{instance | step: label_idx}
              state = %{state | instances: Map.put(state.instances, job_id, instance)}
              advance_step(job_id, clock, state)

            {{:batch, count}, _idx} ->
              step_key = instance.step
              buffer = Map.get(state.batch_buffer, step_key, [])
              buffer = [job_id | buffer]

              if length(buffer) >= count do
                # Batch complete — advance all buffered jobs
                state = %{state | batch_buffer: Map.delete(state.batch_buffer, step_key)}

                {state, all_events} =
                  Enum.reduce(buffer, {state, []}, fn jid, {st, evts} ->
                    inst = Map.fetch!(st.instances, jid)
                    inst = %{inst | step: inst.step + 1}
                    st = %{st | instances: Map.put(st.instances, jid, inst)}
                    {:ok, st, new_evts} = advance_step(jid, clock, st)
                    {st, evts ++ new_evts}
                  end)

                {:ok, state, all_events}
              else
                # Not enough yet — park this job
                state = %{state | batch_buffer: Map.put(state.batch_buffer, step_key, buffer)}
                {:ok, state, []}
              end

            {{:label, _name}, _idx} ->
              # Labels are no-ops — just advance to next step
              instance = %{instance | step: instance.step + 1}
              state = %{state | instances: Map.put(state.instances, job_id, instance)}
              advance_step(job_id, clock, state)

            {{:route, dist}, _idx} ->
              # Travel delay — like hold but no resource seize/release
              # Don't increment step here — hold_complete handler does it
              {duration, rand_state} = sample_dist(dist, state.rand_state)
              state = %{state | rand_state: rand_state}
              handle_hold(job_id, duration, clock, state)

            {{:split, count}, _idx} ->
              # One part becomes N parts. Original continues, N-1 new instances created.
              instance = %{instance | step: instance.step + 1}
              state = %{state | instances: Map.put(state.instances, job_id, instance)}

              # Create N-1 clones at the same step
              base_id = job_id * 1_000_000

              {state, clone_events} =
                Enum.reduce(1..(count - 1), {state, []}, fn i, {st, evts} ->
                  clone_id = base_id + i
                  clone_instance = %{instance | arrival_time: clock_to_float(clock, 0)}
                  st = %{st | instances: Map.put(st.instances, clone_id, clone_instance)}
                  {:ok, st, new_evts} = advance_step(clone_id, clock, st)
                  {st, evts ++ new_evts}
                end)

              # Advance original
              {:ok, state, orig_events} = advance_step(job_id, clock, state)
              {:ok, state, clone_events ++ orig_events}

            {{:combine, count}, _idx} ->
              # N parts merge into 1. Like batch, but only one continues; rest are consumed.
              step_key = {:combine, instance.step}
              buffer = Map.get(state.batch_buffer, step_key, [])
              buffer = [job_id | buffer]

              if length(buffer) >= count do
                # Combine complete — first part continues, rest are consumed
                [survivor | consumed] = buffer
                state = %{state | batch_buffer: Map.delete(state.batch_buffer, step_key)}

                # Remove consumed parts
                state =
                  Enum.reduce(consumed, state, fn cid, st ->
                    %{st | instances: Map.delete(st.instances, cid)}
                  end)

                # Advance survivor
                inst = Map.fetch!(state.instances, survivor)
                inst = %{inst | step: inst.step + 1}
                state = %{state | instances: Map.put(state.instances, survivor, inst)}
                advance_step(survivor, clock, state)
              else
                # Not enough yet — park this part
                state = %{state | batch_buffer: Map.put(state.batch_buffer, step_key, buffer)}
                {:ok, state, []}
              end
          end
        end

        defp find_label(flow, label_name) do
          case Enum.find(flow, fn
                 {{:label, name}, _idx} -> name == label_name
                 _ -> false
               end) do
            {_, idx} -> idx
            nil -> raise "Label :#{label_name} not found in process flow"
          end
        end

        defp handle_hold(job_id, duration, clock, state) do
          event =
            case state.mode do
              :diasca ->
                ticks = max(1, round(duration))
                {:delay, ticks, state.id, {:hold_complete, job_id}}

              _ ->
                {clock_to_float(clock, 0) + duration, state.id, {:hold_complete, job_id}}
            end

          {:ok, state, [event]}
        end

        # --- Helpers ---

        defp make_event(clock, :diasca, target, payload) do
          {:same_tick, target, payload}
        end

        defp make_event(clock, _mode, target, payload) do
          {clock_to_float(clock, 0), target, payload}
        end

        defp clock_to_float({_tick, _diasca} = td, _default), do: elem(td, 0) * 1.0
        defp clock_to_float(clock, _default) when is_float(clock), do: clock
        defp clock_to_float(clock, default) when is_number(clock), do: clock * 1.0
        defp clock_to_float(_, default), do: default

        defp sample_dist({:exponential, mean}, rs) do
          {u, rs} = :rand.uniform_s(rs)
          {-mean * :math.log(u), rs}
        end

        defp sample_dist({:constant, value}, rs), do: {value, rs}

        defp sample_dist({:uniform, {a, b}}, rs) do
          {u, rs} = :rand.uniform_s(rs)
          {a + u * (b - a), rs}
        end
      end
    end
  end
end
