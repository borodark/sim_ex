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

defmodule Sim.StathamTest do
  use ExUnit.Case
  use PropCheck
  use PropCheck.StateM

  @moduletag timeout: 120_000

  property "engine invariants hold under adversarial sequences", [:verbose, numtests: 200] do
    forall cmds <- commands(Sim.Statham) do
      Process.delete(:statham_engine)

      {history, state, result} = run_commands(Sim.Statham, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        === proper_statham FAILURE ===
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result)}
        History: #{length(history)} steps
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end
end
