defmodule Sim.Bench.Factory do
  @moduledoc """
  Configurable factory model for benchmarking.

  Generates a job shop with N machines in S stages, M jobs arriving
  per unit time. Jobs flow through stages sequentially. Each stage
  has configurable capacity and service time distribution.

  Scales from barbershop (1 stage, 1 machine) to semiconductor fab
  (50 stages, 300 machines).
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :stage,
    :num_stages,
    :next_stage,
    :service_dist,
    :service_mean,
    :rand_state,
    capacity: 1,
    busy: 0,
    queue: :queue.new(),
    arrivals: 0,
    departures: 0,
    total_wait: 0.0,
    total_service: 0.0
  ]

  @impl true
  def init(config) do
    seed = config[:seed] || :erlang.phash2(config.id)

    {:ok,
     %__MODULE__{
       id: config.id,
       stage: config[:stage] || 0,
       num_stages: config[:num_stages] || 1,
       next_stage: config[:next_stage],
       capacity: config[:capacity] || 1,
       service_dist: config[:service_dist] || :exponential,
       service_mean: config[:service_mean] || 1.0,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  @impl true
  def handle_event({:arrive, job_id, arrival_time}, clock, state) do
    state = %{state | arrivals: state.arrivals + 1}

    if state.busy < state.capacity do
      {service_time, rs} = sample(state)
      depart_time = clock + service_time

      state = %{
        state
        | busy: state.busy + 1,
          rand_state: rs,
          total_wait: state.total_wait + 0.0,
          total_service: state.total_service + service_time
      }

      {:ok, state, [{depart_time, state.id, {:depart, job_id, arrival_time}}]}
    else
      state = %{state | queue: :queue.in({job_id, arrival_time, clock}, state.queue)}
      {:ok, state, []}
    end
  end

  def handle_event({:depart, job_id, original_arrival}, clock, state) do
    state = %{state | departures: state.departures + 1}

    # Forward to next stage or sink
    forward_events =
      if state.next_stage do
        [{clock, state.next_stage, {:arrive, job_id, original_arrival}}]
      else
        []
      end

    # Serve next in queue
    case :queue.out(state.queue) do
      {{:value, {next_job, orig_arr, enqueue_time}}, queue} ->
        wait = clock - enqueue_time
        {service_time, rs} = sample(state)
        depart_time = clock + service_time

        state = %{
          state
          | queue: queue,
            rand_state: rs,
            total_wait: state.total_wait + wait,
            total_service: state.total_service + service_time
        }

        depart_event = [{depart_time, state.id, {:depart, next_job, orig_arr}}]
        {:ok, state, forward_events ++ depart_event}

      {:empty, _} ->
        {:ok, %{state | busy: state.busy - 1}, forward_events}
    end
  end

  @impl true
  def statistics(state) do
    n = state.departures

    %{
      arrivals: state.arrivals,
      departures: n,
      queue_length: :queue.len(state.queue),
      mean_wait: if(n > 0, do: state.total_wait / n, else: 0.0),
      mean_service: if(n > 0, do: state.total_service / n, else: 0.0),
      utilization: state.busy / state.capacity
    }
  end

  defp sample(%{service_dist: :exponential, service_mean: mean, rand_state: rs}) do
    {u, rs} = :rand.uniform_s(rs)
    {-mean * :math.log(u), rs}
  end

  defp sample(%{service_dist: :uniform, service_mean: mean, rand_state: rs}) do
    {u, rs} = :rand.uniform_s(rs)
    {mean * 0.5 + u * mean, rs}
  end

  # --- Factory builder ---

  @doc """
  Build a factory configuration with `num_stages` sequential stages.

  Returns `{entities, initial_events}` ready for `Sim.run/1`.

  ## Options
  - `:num_stages` — number of sequential processing stages (default: 5)
  - `:machines_per_stage` — capacity at each stage (default: 2)
  - `:interarrival` — mean interarrival time (default: 1.0)
  - `:service_mean` — mean service time per stage (default: 0.8)
  - `:seed` — base PRNG seed (default: 42)
  """
  def build(opts \\ []) do
    num_stages = opts[:num_stages] || 5
    machines = opts[:machines_per_stage] || 2
    ia_mean = opts[:interarrival] || 1.0
    svc_mean = opts[:service_mean] || 0.8
    seed = opts[:seed] || 42

    # Build stage entities
    stage_ids = for s <- 0..(num_stages - 1), do: :"stage_#{s}"

    stage_entities =
      stage_ids
      |> Enum.with_index()
      |> Enum.map(fn {id, idx} ->
        next = if idx < num_stages - 1, do: Enum.at(stage_ids, idx + 1), else: nil

        {id, __MODULE__,
         %{
           id: id,
           stage: idx,
           num_stages: num_stages,
           next_stage: next,
           capacity: machines,
           service_mean: svc_mean,
           seed: seed + idx
         }}
      end)

    # Source entity
    source =
      {:source, Sim.Source,
       %{
         id: :source,
         target: hd(stage_ids),
         interarrival: {:exponential, ia_mean},
         seed: seed + 1000
       }}

    entities = [source | stage_entities]
    initial_events = [{0.0, :source, :generate}]

    {entities, initial_events}
  end
end
