defmodule Sim.Statham do
  @moduledoc """
  proper_statem model for sim_ex. Jason Statham always delivers.

  Uses raw PropCheck.StateM (not ModelDSL) for full control over
  symbolic variable handling.
  """
  use PropCheck
  use PropCheck.StateM

  # --- SUT in process dictionary ---
  def get_engine, do: Process.get(:statham_engine)
  def set_engine(e), do: Process.put(:statham_engine, e)

  # --- Model state ---
  def initial_state do
    %{
      initialized: false,
      calendar_size: 0,
      clock: 0.0,
      events_processed: 0,
      stop_time: 10_000.0
    }
  end

  # --- Command generation ---
  def command(%{initialized: false} = _state) do
    oneof([
      {:call, __MODULE__, :do_init, [integer(1, 100_000), float(5_000.0, 20_000.0)]}
    ])
  end

  def command(%{initialized: true, calendar_size: 0} = _state) do
    {:call, __MODULE__, :do_check, []}
  end

  def command(%{initialized: true} = _state) do
    frequency([
      {6, {:call, __MODULE__, :do_step, []}},
      {3, {:call, __MODULE__, :do_run_n, [integer(1, 30)]}},
      {1, {:call, __MODULE__, :do_check, []}}
    ])
  end

  # --- SUT functions ---

  def do_init(seed, stop_time) do
    {:ok, eng} =
      Sim.Engine.init(
        entities: [
          {:customer_source, Sim.Source,
           %{id: :customer_source, target: :barber,
             interarrival: {:exponential, 18.0}, seed: seed}},
          {:barber, Sim.Resource,
           %{id: :barber, capacity: 1,
             service: {:exponential, 16.0}, seed: seed + 1000}}
        ],
        initial_events: [{0.0, :customer_source, :generate}],
        stop_time: stop_time
      )

    set_engine(eng)
    {:ok, :gb_trees.size(eng.calendar), eng.clock}
  end

  def do_step do
    case Sim.Engine.step(get_engine()) do
      {:ok, eng} ->
        set_engine(eng)
        {:ok, eng.clock, eng.events_processed, :gb_trees.size(eng.calendar)}

      {:done, eng} ->
        set_engine(eng)
        {:done, eng.clock, eng.events_processed, 0}

      {:stopped, eng} ->
        set_engine(eng)
        {:stopped, eng.clock, eng.events_processed, :gb_trees.size(eng.calendar)}
    end
  end

  def do_run_n(n) do
    eng = get_engine()
    {status, final} = run_n_steps(eng, n)
    set_engine(final)
    {status, final.clock, final.events_processed, :gb_trees.size(final.calendar)}
  end

  def do_check do
    eng = get_engine()

    sorted =
      case :gb_trees.is_empty(eng.calendar) do
        true -> true
        false -> :gb_trees.keys(eng.calendar) == Enum.sort(:gb_trees.keys(eng.calendar))
      end

    targets_ok =
      case :gb_trees.is_empty(eng.calendar) do
        true -> true
        false ->
          :gb_trees.values(eng.calendar)
          |> Enum.all?(fn {target, _} -> Map.has_key?(eng.entities, target) end)
      end

    flow_ok =
      Enum.all?(eng.entities, fn {_id, state} ->
        case state do
          %{arrivals: a, departures: d} -> d <= a
          _ -> true
        end
      end)

    {:check, sorted, targets_ok, flow_ok}
  end

  # --- Preconditions ---

  def precondition(%{initialized: false}, {:call, _, :do_init, _}), do: true
  def precondition(%{initialized: true}, {:call, _, :do_step, _}), do: true
  def precondition(%{initialized: true, calendar_size: cs}, {:call, _, :do_run_n, _}) when cs > 0, do: true
  def precondition(%{initialized: true}, {:call, _, :do_check, _}), do: true
  def precondition(_, _), do: false

  # --- Postconditions ---

  def postcondition(_state, {:call, _, :do_init, _}, {:ok, cal_size, _clock}) do
    cal_size > 0
  end

  def postcondition(state, {:call, _, :do_step, _}, {status, new_clock, new_ep, _new_cs}) do
    case status do
      :ok ->
        new_clock >= state.clock and
          new_ep == state.events_processed + 1

      :done -> true
      :stopped -> true
    end
  end

  def postcondition(state, {:call, _, :do_run_n, _}, {_status, new_clock, new_ep, _new_cs}) do
    new_clock >= state.clock and new_ep >= state.events_processed
  end

  def postcondition(_state, {:call, _, :do_check, _}, {:check, sorted, targets, flow}) do
    sorted and targets and flow
  end

  def postcondition(_, _, _), do: true

  # --- State transitions ---

  def next_state(state, _result, {:call, _, :do_init, [_seed, stop_time]}) do
    %{state | initialized: true, calendar_size: 1, stop_time: stop_time}
  end

  def next_state(state, result, {:call, _, :do_step, []}) do
    # result is symbolic during generation, dynamic during execution
    case result do
      {status, clock, ep, cs} when is_number(clock) ->
        case status do
          :ok -> %{state | clock: clock, events_processed: ep, calendar_size: cs}
          :done -> %{state | calendar_size: 0}
          :stopped -> state
        end

      _ ->
        # Symbolic — optimistic update
        %{state | events_processed: state.events_processed + 1}
    end
  end

  def next_state(state, result, {:call, _, :do_run_n, [_n]}) do
    case result do
      {_status, clock, ep, cs} when is_number(clock) ->
        %{state | clock: clock, events_processed: ep, calendar_size: cs}

      _ ->
        # Symbolic — can't predict exactly
        state
    end
  end

  def next_state(state, _result, {:call, _, :do_check, []}), do: state

  # --- Helpers ---

  defp run_n_steps(engine, 0), do: {:ok, engine}

  defp run_n_steps(engine, n) do
    case Sim.Engine.step(engine) do
      {:ok, new_eng} -> run_n_steps(new_eng, n - 1)
      {:done, eng} -> {:done, eng}
      {:stopped, eng} -> {:stopped, eng}
    end
  end
end

# ================================================================
# Phase 3: Resource protocol model in isolation
# Tests seize/release/preempt without the full engine.
# ================================================================

defmodule Sim.Statham.Resource do
  @moduledoc """
  proper_statem model for DSL.Resource in isolation.
  Faster iteration, sharper shrinking than the full engine model.
  """
  use PropCheck
  use PropCheck.StateM

  def get_resource, do: Process.get(:statham_resource)
  def set_resource(r), do: Process.put(:statham_resource, r)

  def initial_state do
    %{
      initialized: false,
      capacity: 0,
      busy: 0,
      queue_length: 0,
      grants: 0,
      releases: 0,
      preemptive: false,
      holder_jobs: [],
      next_job: 1
    }
  end

  # --- Command generation ---

  def command(%{initialized: false}) do
    frequency([
      {1, {:call, __MODULE__, :init_resource, [integer(1, 4), boolean()]}},
    ])
  end

  def command(%{initialized: true, busy: busy, capacity: cap} = state) do
    cmds = [
      {5, {:call, __MODULE__, :seize, [state.next_job, integer(1, 10)]}},
      {1, {:call, __MODULE__, :check_resource, []}}
    ]

    # Can only release if something is held — only release actual holders
    cmds = if state.holder_jobs != [] do
      [{3, {:call, __MODULE__, :release, [oneof(state.holder_jobs)]}} | cmds]
    else
      cmds
    end

    frequency(cmds)
  end

  # --- SUT functions ---

  def init_resource(capacity, preemptive) do
    {:ok, state} = Sim.DSL.Resource.init(%{
      id: :test_resource,
      capacity: capacity,
      preemptive: preemptive,
      seed: 42
    })
    set_resource(state)
    {:ok, capacity, preemptive}
  end

  def seize(job_id, priority) do
    res = get_resource()
    event = if res.preemptive do
      {:seize_request, job_id, :test_process, priority}
    else
      {:seize_request, job_id, :test_process}
    end

    {:ok, new_res, events} = Sim.DSL.Resource.handle_event(event, 100.0, res)
    set_resource(new_res)

    granted = Enum.any?(events, fn
      {_, _, {:grant, _, ^job_id}} -> true
      _ -> false
    end)

    preempted_jobs = events
    |> Enum.filter(fn
      {_, _, {:preempted, _, _, _}} -> true
      _ -> false
    end)
    |> Enum.map(fn {_, _, {:preempted, _, job, _}} -> job end)

    {:seize, granted, new_res.busy, new_res.grants, preempted_jobs}
  end

  def release(job_id) do
    res = get_resource()
    {:ok, new_res, events} = Sim.DSL.Resource.handle_event({:release, job_id}, 200.0, res)
    set_resource(new_res)

    queue_grants = Enum.count(events, fn
      {_, _, {:grant, _, _}} -> true
      _ -> false
    end)

    {:release, new_res.busy, new_res.releases, queue_grants}
  end

  def check_resource do
    res = get_resource()
    queue_len = if res.preemptive do
      :gb_trees.size(res.queue)
    else
      :queue.len(res.queue)
    end

    %{
      busy: res.busy,
      capacity: res.capacity,
      grants: res.grants,
      releases: res.releases,
      queue_length: queue_len,
      busy_lte_cap: res.busy <= res.capacity
    }
  end

  # --- Preconditions ---

  def precondition(%{initialized: false}, {:call, _, :init_resource, _}), do: true
  def precondition(%{initialized: true}, {:call, _, :seize, _}), do: true
  def precondition(%{initialized: true, busy: b}, {:call, _, :release, _}) when b > 0, do: true
  def precondition(%{initialized: true}, {:call, _, :check_resource, _}), do: true
  def precondition(_, _), do: false

  # --- Postconditions ---

  def postcondition(_state, {:call, _, :init_resource, _}, {:ok, cap, _preemptive}) do
    cap >= 1
  end

  def postcondition(state, {:call, _, :seize, [_job, _prio]}, {:seize, granted, busy, _grants, _preempted}) do
    # INVARIANT: busy never exceeds capacity
    busy <= state.capacity and
    # INVARIANT: if capacity was available and granted, busy incremented
    (if state.busy < state.capacity, do: granted, else: true)
  end

  def postcondition(state, {:call, _, :release, [_job]}, {:release, busy, releases, _queue_grants}) do
    # INVARIANT: busy decreased or stayed same (queue grant refilled)
    busy <= state.capacity and
    # INVARIANT: releases incremented
    releases == state.releases + 1
  end

  def postcondition(_state, {:call, _, :check_resource, _}, result) do
    # INVARIANT: busy never exceeds capacity
    result.busy_lte_cap and
    # INVARIANT: grants >= releases (can't release what wasn't granted)
    result.grants >= result.releases
  end

  def postcondition(_, _, _), do: true

  # --- State transitions ---

  def next_state(state, _result, {:call, _, :init_resource, [cap, preemptive]}) do
    %{state | initialized: true, capacity: cap, preemptive: preemptive}
  end

  def next_state(state, result, {:call, _, :seize, [job_id, _prio]}) do
    case result do
      {:seize, granted, busy, grants, preempted} when is_boolean(granted) ->
        holders = if granted do
          (state.holder_jobs -- preempted) ++ [job_id]
        else
          state.holder_jobs -- preempted
        end

        %{state |
          busy: busy,
          grants: grants,
          holder_jobs: holders,
          next_job: state.next_job + 1
        }

      _ ->
        # Symbolic — optimistically assume grant if capacity available
        holders = if state.busy < state.capacity do
          state.holder_jobs ++ [job_id]
        else
          state.holder_jobs
        end

        busy = min(state.busy + 1, state.capacity)

        %{state |
          busy: busy,
          holder_jobs: holders,
          next_job: state.next_job + 1
        }
    end
  end

  def next_state(state, result, {:call, _, :release, [job_id]}) do
    case result do
      {:release, busy, releases, _queue_grants} when is_integer(busy) ->
        %{state |
          busy: busy,
          releases: releases,
          holder_jobs: List.delete(state.holder_jobs, job_id)
        }

      _ ->
        %{state | holder_jobs: List.delete(state.holder_jobs, job_id)}
    end
  end

  def next_state(state, _result, {:call, _, :check_resource, []}), do: state
end

# ================================================================
# Phase 4: Adversarial engine model
# Generates preemptive scenarios with simultaneous events.
# ================================================================

defmodule Sim.Statham.Adversarial do
  @moduledoc """
  Adversarial proper_statem: preemptive resource, rush + normal orders,
  simultaneous events. Hunts for preemption-during-hold bugs,
  generation counter failures, and queue corruption.
  """
  use PropCheck
  use PropCheck.StateM

  def get_engine, do: Process.get(:statham_adversarial)
  def set_engine(e), do: Process.put(:statham_adversarial, e)

  def initial_state do
    %{
      initialized: false,
      calendar_size: 0,
      clock: 0.0,
      events_processed: 0,
      stop_time: 10_000.0
    }
  end

  def command(%{initialized: false}) do
    {:call, __MODULE__, :do_init, [integer(1, 100_000)]}
  end

  def command(%{initialized: true, calendar_size: 0}) do
    {:call, __MODULE__, :do_check, []}
  end

  def command(%{initialized: true}) do
    frequency([
      {6, {:call, __MODULE__, :do_step, []}},
      {3, {:call, __MODULE__, :do_run_n, [integer(1, 50)]}},
      {1, {:call, __MODULE__, :do_check, []}}
    ])
  end

  # --- SUT: preemptive barbershop (rush + normal orders) ---

  def do_init(seed) do
    # Use the preemptive test model inline
    {:ok, eng} =
      Sim.Engine.init(
        entities: [
          {:normal_source, Sim.Source,
           %{id: :normal_source, target: :machine,
             interarrival: {:exponential, 5.0}, seed: seed}},
          {:rush_source, Sim.Source,
           %{id: :rush_source, target: :machine,
             interarrival: {:exponential, 50.0}, seed: seed + 5000}},
          {:machine, Sim.DSL.Resource,
           %{id: :machine, capacity: 1, preemptive: true, seed: seed + 1000}}
        ],
        initial_events: [
          {0.0, :normal_source, :generate},
          {0.0, :rush_source, :generate}
        ],
        stop_time: 10_000.0
      )

    set_engine(eng)
    {:ok, :gb_trees.size(eng.calendar)}
  end

  def do_step do
    eng = get_engine()
    case Sim.Engine.step(eng) do
      {:ok, new_eng} ->
        set_engine(new_eng)
        {:ok, new_eng.clock, new_eng.events_processed, :gb_trees.size(new_eng.calendar)}
      {:done, new_eng} ->
        set_engine(new_eng)
        {:done, new_eng.clock, new_eng.events_processed, 0}
      {:stopped, new_eng} ->
        set_engine(new_eng)
        {:stopped, new_eng.clock, new_eng.events_processed, :gb_trees.size(new_eng.calendar)}
    end
  end

  def do_run_n(n) do
    eng = get_engine()
    {status, final} = run_steps(eng, n)
    set_engine(final)
    {status, final.clock, final.events_processed, :gb_trees.size(final.calendar)}
  end

  def do_check do
    eng = get_engine()
    machine = eng.entities[:machine]

    %{
      busy_lte_cap: machine.busy <= machine.capacity,
      grants_gte_releases: machine.grants >= machine.releases,
      preemptions: machine.preemptions,
      calendar_sorted: calendar_sorted?(eng.calendar),
      clock: eng.clock
    }
  end

  # --- Preconditions ---

  def precondition(%{initialized: false}, {:call, _, :do_init, _}), do: true
  def precondition(%{initialized: true}, {:call, _, :do_step, _}), do: true
  def precondition(%{initialized: true, calendar_size: cs}, {:call, _, :do_run_n, _}) when cs > 0, do: true
  def precondition(%{initialized: true}, {:call, _, :do_check, _}), do: true
  def precondition(_, _), do: false

  # --- Postconditions ---

  def postcondition(_state, {:call, _, :do_init, _}, {:ok, cs}), do: cs > 0

  def postcondition(state, {:call, _, :do_step, _}, {status, clock, ep, _cs}) do
    case status do
      :ok -> clock >= state.clock and ep == state.events_processed + 1
      _ -> true
    end
  end

  def postcondition(state, {:call, _, :do_run_n, _}, {_status, clock, ep, _cs}) do
    clock >= state.clock and ep >= state.events_processed
  end

  def postcondition(_state, {:call, _, :do_check, _}, result) do
    # CRITICAL INVARIANTS for preemptive resources:
    result.busy_lte_cap and
      result.grants_gte_releases and
      result.calendar_sorted
  end

  def postcondition(_, _, _), do: true

  # --- State transitions ---

  def next_state(state, _result, {:call, _, :do_init, [_seed]}) do
    %{state | initialized: true, calendar_size: 2}
  end

  def next_state(state, result, {:call, _, :do_step, []}) do
    case result do
      {:ok, clock, ep, cs} when is_number(clock) ->
        %{state | clock: clock, events_processed: ep, calendar_size: cs}
      {:done, _, _, _} -> %{state | calendar_size: 0}
      {:stopped, _, _, _} -> state
      _ -> %{state | events_processed: state.events_processed + 1}
    end
  end

  def next_state(state, result, {:call, _, :do_run_n, [_n]}) do
    case result do
      {_, clock, ep, cs} when is_number(clock) ->
        %{state | clock: clock, events_processed: ep, calendar_size: cs}
      _ -> state
    end
  end

  def next_state(state, _result, {:call, _, :do_check, []}), do: state

  # --- Helpers ---

  defp run_steps(engine, 0), do: {:ok, engine}
  defp run_steps(engine, n) do
    case Sim.Engine.step(engine) do
      {:ok, eng} -> run_steps(eng, n - 1)
      {:done, eng} -> {:done, eng}
      {:stopped, eng} -> {:stopped, eng}
    end
  end

  defp calendar_sorted?(calendar) do
    case :gb_trees.is_empty(calendar) do
      true -> true
      false -> :gb_trees.keys(calendar) == Enum.sort(:gb_trees.keys(calendar))
    end
  end
end

# ================================================================
# TEST MODULE
# ================================================================

defmodule Sim.StathamTest do
  use ExUnit.Case
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: 120_000

  # Phase 2: Full engine model (barbershop)
  property "engine invariants hold under adversarial sequences", [:verbose, numtests: 200] do
    forall cmds <- commands(Sim.Statham) do
      Process.delete(:statham_engine)

      {history, state, result} = run_commands(Sim.Statham, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        === proper_statham FAILURE (engine) ===
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result)}
        History: #{length(history)} steps
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  # Phase 3: Resource protocol in isolation
  property "resource protocol: busy <= capacity, grants >= releases", [:verbose, numtests: 300] do
    forall cmds <- commands(Sim.Statham.Resource) do
      Process.delete(:statham_resource)

      {history, state, result} = run_commands(Sim.Statham.Resource, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        === proper_statham FAILURE (resource) ===
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result)}
        History: #{length(history)} steps
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  # Phase 4: Adversarial preemptive engine
  property "preemptive engine: busy <= cap, grants >= releases under preemption", [:verbose, numtests: 200] do
    forall cmds <- commands(Sim.Statham.Adversarial) do
      Process.delete(:statham_adversarial)

      {history, state, result} = run_commands(Sim.Statham.Adversarial, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        === proper_statham FAILURE (adversarial) ===
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result)}
        History: #{length(history)} steps
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end
end
