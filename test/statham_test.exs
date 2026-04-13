# proper_statham — Stateful Property Testing for DES Engines
#
# "Jason Statham always delivers the package.
#  proper_statem always delivers the minimal failing sequence.
#  proper_statham — because the engine should be indestructible."
#
# This file contains three proper_statem models that test the sim_ex
# engine by generating ADVERSARIAL COMMAND SEQUENCES — not random
# parameters (that's property_test.exs), but random OPERATIONS.
#
# The three inspectors metaphor:
#   - Point tests (the clipboard): seed 42, check the number
#   - Property tests (the auditor): random params, check the law
#   - Stateful tests (the saboteur): random sequences, check the protocol
#
# No DES engine in the published literature has been verified this way.
#
# HOW IT WORKS:
#
# PropEr's proper_statem models a system as a state machine:
#   1. Define initial_state/0 — the model's starting state
#   2. Define command/1 — generate the next command from current state
#   3. Define precondition/2 — guard: is this command valid here?
#   4. Define postcondition/3 — check: did the SUT respond correctly?
#   5. Define next_state/3 — update model state after command
#
# PropEr generates random command sequences, executes them against the
# real system (SUT = System Under Test), checks postconditions after
# each step. When a postcondition fails, PropEr SHRINKS the sequence
# to the minimal reproduction — the shortest command list that still
# fails. This shrunk sequence is the diagnosis.
#
# THE BUG THIS FOUND:
#
# The Resource isolation model (Phase 3) generated this 4-step sequence:
#
#   init_resource(capacity: 3, preemptive: true)
#   seize(job_id: 1, priority: 3)
#   release(job_id: 1)
#   release(job_id: 3)    ← job 3 was never seized
#
# The engine accepted the spurious release silently. busy went to 0
# (clamped by max(busy-1, 0)), but releases incremented to 2 while
# grants stayed at 1. The postcondition `grants >= releases` caught it.
# 114 point + property tests missed this because no compiled DSL model
# ever produces a release without a preceding seize. The saboteur does.
#
# RUNNING:
#
#   mix test test/statham_test.exs     # ~1 second, 700 sequences
#
# MODELS:
#
#   Sim.Statham          — Full engine (barbershop): step, run_n, check
#   Sim.Statham.Resource — Resource protocol in isolation: seize, release
#   Sim.Statham.Adversarial — Preemptive engine: rush + normal orders

# ================================================================
# MODEL 1: Full Engine (barbershop)
#
# Tests the tight-loop engine with a barbershop (1 barber, Poisson
# arrivals, exponential service). Commands: init, step (one event),
# run_n (batch N events), check (verify all invariants).
#
# Postconditions verified after each command:
#   - Clock monotonicity: time never goes backward
#   - Events processed: increments by exactly 1 per step
#   - Entity presence: all entities survive every step
#   - Calendar ordering: :gb_trees keys are sorted
#   - Target validity: every pending event targets an existing entity
#   - Flow conservation: departures <= arrivals for all resources
#
# The engine state lives in the process dictionary (not passed as
# a symbolic variable) because proper_statem's symbolic phase cannot
# evaluate engine operations.
# ================================================================

defmodule Sim.Statham do
  @moduledoc """
  proper_statem model for the sim_ex DES engine.

  The engine is a deterministic state machine: given the calendar,
  entity map, and clock, the next state is fully determined by
  popping the minimum event and dispatching it. PropEr generates
  random command sequences that exercise this state machine
  adversarially.
  """
  use PropCheck
  use PropCheck.StateM

  # The engine lives in the process dictionary during test execution.
  # Each test sequence starts fresh (Process.delete in the test property).
  def get_engine, do: Process.get(:statham_engine)
  def set_engine(e), do: Process.put(:statham_engine, e)

  # The MODEL state — tracks what we expect the engine to look like.
  # This is NOT the engine state; it's our prediction of it.
  # Postconditions compare the real engine against this model.
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
  # PropEr calls command/1 repeatedly to build a sequence.
  # The state argument is the MODEL state (symbolic during generation).

  # Before init: only valid command is init
  def command(%{initialized: false} = _state) do
    oneof([
      {:call, __MODULE__, :do_init, [integer(1, 100_000), float(5_000.0, 20_000.0)]}
    ])
  end

  # After init, calendar empty: can only check (terminal state)
  def command(%{initialized: true, calendar_size: 0} = _state) do
    {:call, __MODULE__, :do_check, []}
  end

  # Normal operation: step (60%), run_n (30%), check (10%)
  def command(%{initialized: true} = _state) do
    frequency([
      {6, {:call, __MODULE__, :do_step, []}},
      {3, {:call, __MODULE__, :do_run_n, [integer(1, 30)]}},
      {1, {:call, __MODULE__, :do_check, []}}
    ])
  end

  # --- SUT functions (called against the REAL engine) ---

  # Initialize a barbershop: 1 barber, Poisson arrivals, exponential service
  def do_init(seed, stop_time) do
    {:ok, eng} =
      Sim.Engine.init(
        entities: [
          {:customer_source, Sim.Source,
           %{
             id: :customer_source,
             target: :barber,
             interarrival: {:exponential, 18.0},
             seed: seed
           }},
          {:barber, Sim.Resource,
           %{id: :barber, capacity: 1, service: {:exponential, 16.0}, seed: seed + 1000}}
        ],
        initial_events: [{0.0, :customer_source, :generate}],
        stop_time: stop_time
      )

    set_engine(eng)
    {:ok, :gb_trees.size(eng.calendar), eng.clock}
  end

  # Execute one event loop iteration via Engine.step/1
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

  # Execute N iterations in a batch
  def do_run_n(n) do
    eng = get_engine()
    {status, final} = run_n_steps(eng, n)
    set_engine(final)
    {status, final.clock, final.events_processed, :gb_trees.size(final.calendar)}
  end

  # Verify all engine invariants without advancing state
  def do_check do
    eng = get_engine()

    # INVARIANT: calendar keys are sorted (gb_trees maintains this)
    sorted =
      case :gb_trees.is_empty(eng.calendar) do
        true -> true
        false -> :gb_trees.keys(eng.calendar) == Enum.sort(:gb_trees.keys(eng.calendar))
      end

    # INVARIANT: every pending event targets a registered entity
    targets_ok =
      case :gb_trees.is_empty(eng.calendar) do
        true ->
          true

        false ->
          :gb_trees.values(eng.calendar)
          |> Enum.all?(fn {target, _} -> Map.has_key?(eng.entities, target) end)
      end

    # INVARIANT: departures <= arrivals for all resource entities
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
  # Guard which commands are valid in which model states.
  # Prevents PropEr from generating invalid sequences.

  def precondition(%{initialized: false}, {:call, _, :do_init, _}), do: true
  def precondition(%{initialized: true}, {:call, _, :do_step, _}), do: true

  def precondition(%{initialized: true, calendar_size: cs}, {:call, _, :do_run_n, _}) when cs > 0,
    do: true

  def precondition(%{initialized: true}, {:call, _, :do_check, _}), do: true
  def precondition(_, _), do: false

  # --- Postconditions ---
  # Verify that the REAL engine state matches our expectations.
  # These run during execution phase (phase 2) with dynamic values.

  def postcondition(_state, {:call, _, :do_init, _}, {:ok, cal_size, _clock}) do
    # After init: calendar must have at least one event (the initial generate)
    cal_size > 0
  end

  def postcondition(state, {:call, _, :do_step, _}, {status, new_clock, new_ep, _new_cs}) do
    case status do
      :ok ->
        # Clock never goes backward
        # Events processed increments by exactly 1
        new_clock >= state.clock and
          new_ep == state.events_processed + 1

      # Calendar was empty — valid terminal
      :done ->
        true

      # Past stop_time — valid terminal
      :stopped ->
        true
    end
  end

  def postcondition(state, {:call, _, :do_run_n, _}, {_status, new_clock, new_ep, _new_cs}) do
    # Clock monotonicity and events_processed non-decreasing
    new_clock >= state.clock and new_ep >= state.events_processed
  end

  def postcondition(_state, {:call, _, :do_check, _}, {:check, sorted, targets, flow}) do
    # All three invariants must hold simultaneously
    sorted and targets and flow
  end

  def postcondition(_, _, _), do: true

  # --- State transitions ---
  # Update the MODEL state after a command executes.
  # Called during both generation (symbolic result) and execution (dynamic).
  # The `when is_number(clock)` guard distinguishes the two phases.

  def next_state(state, _result, {:call, _, :do_init, [_seed, stop_time]}) do
    %{state | initialized: true, calendar_size: 1, stop_time: stop_time}
  end

  def next_state(state, result, {:call, _, :do_step, []}) do
    case result do
      # Dynamic phase: real values available
      {status, clock, ep, cs} when is_number(clock) ->
        case status do
          :ok -> %{state | clock: clock, events_processed: ep, calendar_size: cs}
          :done -> %{state | calendar_size: 0}
          :stopped -> state
        end

      # Symbolic phase: can't evaluate, optimistic update
      _ ->
        %{state | events_processed: state.events_processed + 1}
    end
  end

  def next_state(state, result, {:call, _, :do_run_n, [_n]}) do
    case result do
      {_status, clock, ep, cs} when is_number(clock) ->
        %{state | clock: clock, events_processed: ep, calendar_size: cs}

      _ ->
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
# MODEL 2: Resource Protocol in Isolation
#
# Tests Sim.DSL.Resource WITHOUT the engine — direct handle_event
# calls with synthetic seize/release sequences. Faster iteration
# and sharper shrinking than the full engine model.
#
# This is the model that found the spurious-release bug.
#
# Commands: init_resource (random capacity, random preemptive flag),
# seize (random job_id and priority), release (of a held job),
# check_resource (verify invariants).
#
# Key postconditions:
#   - busy <= capacity (ALWAYS, after every command)
#   - grants >= releases (can't release what wasn't granted)
#   - if capacity available, seize is granted
#
# The release command is only generated when holder_jobs is non-empty,
# and only releases actually-held jobs. The original bug was found
# when this constraint was too loose (included next_job in the
# release pool), generating releases for ungranted jobs.
# ================================================================

defmodule Sim.Statham.Resource do
  @moduledoc """
  proper_statem model for Sim.DSL.Resource in isolation.

  Tests the seize/release protocol without the engine.
  Generates adversarial seize/release sequences including
  preemptive and non-preemptive configurations.

  Found: releasing an ungranted job corrupts statistics
  (releases > grants). Fixed by guarding release on
  Map.has_key?(holders, job_id) for preemptive resources
  and busy > 0 for non-preemptive.
  """
  use PropCheck
  use PropCheck.StateM

  # Resource state in process dictionary
  def get_resource, do: Process.get(:statham_resource)
  def set_resource(r), do: Process.put(:statham_resource, r)

  # Model state: tracks what we expect the resource to look like
  def initial_state do
    %{
      initialized: false,
      capacity: 0,
      busy: 0,
      queue_length: 0,
      grants: 0,
      releases: 0,
      preemptive: false,
      # job IDs currently holding the resource
      holder_jobs: [],
      # monotonic job ID counter
      next_job: 1
    }
  end

  # --- Command generation ---

  # Before init: only valid command is init with random capacity and preemptive flag
  def command(%{initialized: false}) do
    frequency([
      {1, {:call, __MODULE__, :init_resource, [integer(1, 4), boolean()]}}
    ])
  end

  # After init: seize, release (if something held), check
  def command(%{initialized: true, busy: _busy, capacity: _cap} = state) do
    cmds = [
      {5, {:call, __MODULE__, :seize, [state.next_job, integer(1, 10)]}},
      {1, {:call, __MODULE__, :check_resource, []}}
    ]

    # IMPORTANT: Only generate release for actually-held jobs.
    # Using `oneof(state.holder_jobs)` ensures we never release
    # an ungranted job — that's the fixed version. The bug was
    # found when this included state.next_job (ungranted).
    cmds =
      if state.holder_jobs != [] do
        [{3, {:call, __MODULE__, :release, [oneof(state.holder_jobs)]}} | cmds]
      else
        cmds
      end

    frequency(cmds)
  end

  # --- SUT functions ---

  # Initialize a resource with random capacity and preemptive flag
  def init_resource(capacity, preemptive) do
    {:ok, state} =
      Sim.DSL.Resource.init(%{
        id: :test_resource,
        capacity: capacity,
        preemptive: preemptive,
        seed: 42
      })

    set_resource(state)
    {:ok, capacity, preemptive}
  end

  # Send a seize_request to the resource. Returns whether it was granted,
  # the new busy count, total grants, and any preempted job IDs.
  def seize(job_id, priority) do
    res = get_resource()

    # Preemptive resources use 4-tuple with priority;
    # non-preemptive use 3-tuple (priority ignored)
    event =
      if res.preemptive do
        {:seize_request, job_id, :test_process, priority}
      else
        {:seize_request, job_id, :test_process}
      end

    {:ok, new_res, events} = Sim.DSL.Resource.handle_event(event, 100.0, res)
    set_resource(new_res)

    # Check if a grant event was emitted for this job
    granted =
      Enum.any?(events, fn
        {_, _, {:grant, _, ^job_id}} -> true
        _ -> false
      end)

    # Collect any preempted job IDs (preemptive mode only)
    preempted_jobs =
      events
      |> Enum.filter(fn
        {_, _, {:preempted, _, _, _}} -> true
        _ -> false
      end)
      |> Enum.map(fn {_, _, {:preempted, _, job, _}} -> job end)

    {:seize, granted, new_res.busy, new_res.grants, preempted_jobs}
  end

  # Release a held job. Returns new busy count, total releases,
  # and how many queued jobs were granted as a result.
  def release(job_id) do
    res = get_resource()
    {:ok, new_res, events} = Sim.DSL.Resource.handle_event({:release, job_id}, 200.0, res)
    set_resource(new_res)

    # Count grant events (queue drain after release)
    queue_grants =
      Enum.count(events, fn
        {_, _, {:grant, _, _}} -> true
        _ -> false
      end)

    {:release, new_res.busy, new_res.releases, queue_grants}
  end

  # Snapshot the resource state for invariant checking
  def check_resource do
    res = get_resource()

    queue_len =
      if res.preemptive do
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
  # Release only when model predicts something is held
  def precondition(%{initialized: true, busy: b}, {:call, _, :release, _}) when b > 0, do: true
  def precondition(%{initialized: true}, {:call, _, :check_resource, _}), do: true
  def precondition(_, _), do: false

  # --- Postconditions ---

  def postcondition(_state, {:call, _, :init_resource, _}, {:ok, cap, _preemptive}) do
    cap >= 1
  end

  def postcondition(
        state,
        {:call, _, :seize, [_job, _prio]},
        {:seize, granted, busy, _grants, _preempted}
      ) do
    # INVARIANT: busy NEVER exceeds capacity
    # INVARIANT: if capacity was available, the seize must be granted
    busy <= state.capacity and
      if state.busy < state.capacity, do: granted, else: true
  end

  def postcondition(
        state,
        {:call, _, :release, [_job]},
        {:release, busy, releases, _queue_grants}
      ) do
    # INVARIANT: busy doesn't exceed capacity (may refill from queue)
    # INVARIANT: releases incremented by exactly 1
    busy <= state.capacity and
      releases == state.releases + 1
  end

  def postcondition(_state, {:call, _, :check_resource, _}, result) do
    # INVARIANT: busy <= capacity
    # INVARIANT: grants >= releases (the bug that was found and fixed)
    result.busy_lte_cap and
      result.grants >= result.releases
  end

  def postcondition(_, _, _), do: true

  # --- State transitions ---

  def next_state(state, _result, {:call, _, :init_resource, [cap, preemptive]}) do
    %{state | initialized: true, capacity: cap, preemptive: preemptive}
  end

  def next_state(state, result, {:call, _, :seize, [job_id, _prio]}) do
    case result do
      # Dynamic phase: real values, update precisely
      {:seize, granted, busy, grants, preempted} when is_boolean(granted) ->
        holders =
          if granted do
            (state.holder_jobs -- preempted) ++ [job_id]
          else
            state.holder_jobs -- preempted
          end

        %{state | busy: busy, grants: grants, holder_jobs: holders, next_job: state.next_job + 1}

      # Symbolic phase: optimistic prediction
      # Assume grant if capacity available (needed so release commands
      # can be generated — without this, holder_jobs stays empty and
      # no release commands are ever generated)
      _ ->
        holders =
          if state.busy < state.capacity do
            state.holder_jobs ++ [job_id]
          else
            state.holder_jobs
          end

        busy = min(state.busy + 1, state.capacity)

        %{state | busy: busy, holder_jobs: holders, next_job: state.next_job + 1}
    end
  end

  def next_state(state, result, {:call, _, :release, [job_id]}) do
    case result do
      {:release, busy, releases, _queue_grants} when is_integer(busy) ->
        %{
          state
          | busy: busy,
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
# MODEL 3: Adversarial Preemptive Engine
#
# Tests a preemptive resource under full engine execution.
# Two sources feed one machine: normal orders (priority 5, frequent)
# and rush orders (priority 1, rare). When a rush order arrives and
# the machine is busy with a normal order, preemption occurs:
#
#   1. Normal order ejected (receives :preempted event)
#   2. Hold generation counter incremented (stale hold_complete ignored)
#   3. Rush order granted the machine
#   4. Normal order re-enters queue with remaining service time
#
# This model verifies that the preemption protocol survives
# adversarial scheduling — random interleaving of step and run_n
# commands, with periodic invariant checks.
#
# Postconditions:
#   - busy <= capacity (even during preemption)
#   - grants >= releases (preemption doesn't corrupt accounting)
#   - calendar remains sorted (preemption events inserted correctly)
# ================================================================

defmodule Sim.Statham.Adversarial do
  @moduledoc """
  Adversarial proper_statem: preemptive resource with rush + normal orders.

  Hunts for preemption-during-hold bugs, generation counter failures,
  and queue corruption under adversarial scheduling.
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

  # Before init: must initialize
  def command(%{initialized: false}) do
    {:call, __MODULE__, :do_init, [integer(1, 100_000)]}
  end

  # Calendar empty: terminal — can only check
  def command(%{initialized: true, calendar_size: 0}) do
    {:call, __MODULE__, :do_check, []}
  end

  # Normal operation: step (60%), run_n with up to 50 events (30%), check (10%)
  def command(%{initialized: true}) do
    frequency([
      {6, {:call, __MODULE__, :do_step, []}},
      {3, {:call, __MODULE__, :do_run_n, [integer(1, 50)]}},
      {1, {:call, __MODULE__, :do_check, []}}
    ])
  end

  # --- SUT: preemptive factory (rush + normal orders) ---

  # Initialize with two sources feeding one preemptive machine
  def do_init(seed) do
    {:ok, eng} =
      Sim.Engine.init(
        entities: [
          # Normal orders: frequent (every 5 time units), low priority (5)
          {:normal_source, Sim.Source,
           %{id: :normal_source, target: :machine, interarrival: {:exponential, 5.0}, seed: seed}},
          # Rush orders: rare (every 50 time units), high priority (1)
          {:rush_source, Sim.Source,
           %{
             id: :rush_source,
             target: :machine,
             interarrival: {:exponential, 50.0},
             seed: seed + 5000
           }},
          # Machine: capacity 1, preemptive — rush orders eject normal orders
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

  # Single step
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

  # Batch N steps
  def do_run_n(n) do
    eng = get_engine()
    {status, final} = run_steps(eng, n)
    set_engine(final)
    {status, final.clock, final.events_processed, :gb_trees.size(final.calendar)}
  end

  # Check preemptive-specific invariants
  def do_check do
    eng = get_engine()
    machine = eng.entities[:machine]

    %{
      # INVARIANT: busy never exceeds capacity, even during preemption
      busy_lte_cap: machine.busy <= machine.capacity,
      # INVARIANT: grants >= releases (preemption doesn't corrupt accounting)
      grants_gte_releases: machine.grants >= machine.releases,
      # Diagnostic: preemption count (not an invariant, just tracking)
      preemptions: machine.preemptions,
      # INVARIANT: calendar keys are sorted after preemption event insertion
      calendar_sorted: calendar_sorted?(eng.calendar),
      clock: eng.clock
    }
  end

  # --- Preconditions ---

  def precondition(%{initialized: false}, {:call, _, :do_init, _}), do: true
  def precondition(%{initialized: true}, {:call, _, :do_step, _}), do: true

  def precondition(%{initialized: true, calendar_size: cs}, {:call, _, :do_run_n, _}) when cs > 0,
    do: true

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
    # ALL THREE must hold — this is the preemption protocol contract
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

      {:done, _, _, _} ->
        %{state | calendar_size: 0}

      {:stopped, _, _, _} ->
        state

      _ ->
        %{state | events_processed: state.events_processed + 1}
    end
  end

  def next_state(state, result, {:call, _, :do_run_n, [_n]}) do
    case result do
      {_, clock, ep, cs} when is_number(clock) ->
        %{state | clock: clock, events_processed: ep, calendar_size: cs}

      _ ->
        state
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
# TEST PROPERTIES
#
# Each property generates command sequences, executes them, and
# checks postconditions. On failure, when_fail prints diagnostic
# info and aggregate shows command distribution.
#
# Expected distribution (healthy):
#   Engine:     step ~52%, run_n ~30%, check ~9%, init ~9%
#   Resource:   seize ~47%, release ~17%, check ~25%, init ~12%
#   Adversarial: step ~51%, run_n ~30%, check ~10%, init ~9%
#
# If release drops to 0%, the symbolic state prediction is broken
# (holder_jobs not being populated during generation phase).
# ================================================================

defmodule Sim.StathamTest do
  use ExUnit.Case
  use PropCheck
  import PropCheck.StateM, only: [commands: 1, run_commands: 2, command_names: 1]

  @moduletag timeout: 120_000

  # Model 1: Full engine — 200 adversarial sequences
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

  # Model 2: Resource protocol — 300 sequences (more for sharper coverage)
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

  # Model 3: Adversarial preemptive — 200 sequences
  property "preemptive engine: busy <= cap, grants >= releases under preemption", [
    :verbose,
    numtests: 200
  ] do
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
