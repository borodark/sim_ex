defmodule Sim.Engine.Rust do
  @moduledoc """
  Rust NIF engine — entire simulation in one NIF call.

  Executes DSL-defined models natively in Rust: BinaryHeap calendar,
  Vec entity states, rand crate distributions. Zero BEAM boundary
  crossing per event. Zero garbage collection.

  Only works with DSL-style models (resources + process flows).
  For custom `Sim.Entity` modules, use the Elixir engines.

  ## Usage

      Sim.run(
        mode: :rust,
        resources: [%{capacity: 1}],
        processes: [%{
          steps: [{:seize, 0}, {:hold, {:exponential, 16.0}}, {:release, 0}, :depart],
          arrival_mean: 18.0
        }],
        stop_tick: 100_000,
        seed: 42,
        batch_size: 1
      )
  """

  def run(opts) do
    resources = Keyword.get(opts, :resources, [])
    processes = Keyword.get(opts, :processes, [])
    stop_tick = Keyword.get(opts, :stop_tick, 10_000)
    seed = Keyword.get(opts, :seed, 42)
    batch_size = Keyword.get(opts, :batch_size, 1)

    # Encode resources
    resource_caps =
      Enum.map(resources, fn r -> Map.get(r, :capacity, 1) end)

    # Encode process steps → list of {type_string, arg1, arg2} tuples
    process_steps =
      Enum.map(processes, fn proc ->
        steps = Map.get(proc, :steps, [])
        Enum.map(steps, &encode_step/1)
      end)

    # Encode arrival means
    arrival_means =
      Enum.map(processes, fn proc -> Map.get(proc, :arrival_mean, 1.0) end)

    # Call NIF
    {:ok, events, completions, mean_waits, mean_holds, grants, releases} =
      Sim.Native.run_simulation(
        process_steps,
        resource_caps,
        arrival_means,
        stop_tick,
        seed,
        batch_size
      )

    # Build result map matching Elixir engine format
    process_stats =
      processes
      |> Enum.with_index()
      |> Enum.map(fn {_proc, i} ->
        {:"process_#{i}", %{
          completed: Enum.at(completions, i, 0),
          mean_wait: Enum.at(mean_waits, i, 0.0),
          mean_hold: Enum.at(mean_holds, i, 0.0)
        }}
      end)
      |> Map.new()

    resource_stats =
      resources
      |> Enum.with_index()
      |> Enum.map(fn {_res, i} ->
        {:"resource_#{i}", %{
          grants: Enum.at(grants, i, 0),
          releases: Enum.at(releases, i, 0)
        }}
      end)
      |> Map.new()

    {:ok, %{
      events: events,
      tick: stop_tick,
      stats: Map.merge(process_stats, resource_stats)
    }}
  end

  # --- Step encoding ---

  defp encode_step({:seize, res_idx}), do: {"seize", res_idx * 1.0, 0.0}
  defp encode_step({:hold, {:exponential, mean}}), do: {"hold_exp", mean * 1.0, 0.0}
  defp encode_step({:hold, {:constant, val}}), do: {"hold_const", val * 1.0, 0.0}
  defp encode_step({:hold, {:uniform, {a, b}}}), do: {"hold_uniform", a * 1.0, b * 1.0}
  defp encode_step({:release, res_idx}), do: {"release", res_idx * 1.0, 0.0}
  defp encode_step(:depart), do: {"depart", 0.0, 0.0}
end
