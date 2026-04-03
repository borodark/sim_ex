defmodule Sim.Bench.DiascaFactory do
  @moduledoc """
  Factory entity for tick-diasca mode. Each machine does real work:
  samples service time, updates statistics, routes to next stage.
  Produces fat diascas — many machines processing simultaneously.
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :next_stage,
    :service_mean,
    :rand_state,
    capacity: 1,
    busy: 0,
    queue: :queue.new(),
    arrivals: 0,
    departures: 0,
    total_wait: 0.0
  ]

  @impl true
  def init(config) do
    seed = config[:seed] || :erlang.phash2(config.id)

    {:ok,
     %__MODULE__{
       id: config.id,
       capacity: config[:capacity] || 1,
       next_stage: config[:next_stage],
       service_mean: config[:service_mean] || 1.0,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  @impl true
  def handle_event({:arrive, job_id, enqueue_tick}, {tick, _diasca}, state) do
    state = %{state | arrivals: state.arrivals + 1}

    if state.busy < state.capacity do
      {service_ticks, rs} = sample_service(state)

      state = %{
        state
        | busy: state.busy + 1,
          rand_state: rs,
          total_wait: state.total_wait + max(0, tick - enqueue_tick)
      }

      {:ok, state, [{:delay, service_ticks, state.id, {:depart, job_id}}]}
    else
      state = %{state | queue: :queue.in({job_id, tick}, state.queue)}
      {:ok, state, []}
    end
  end

  def handle_event({:depart, job_id}, {tick, _diasca}, state) do
    state = %{state | departures: state.departures + 1}

    forward =
      if state.next_stage do
        [{:same_tick, state.next_stage, {:arrive, job_id, tick}}]
      else
        []
      end

    case :queue.out(state.queue) do
      {{:value, {next_job, enqueue_tick}}, queue} ->
        wait = max(0, tick - enqueue_tick)
        {service_ticks, rs} = sample_service(state)

        state = %{state | queue: queue, rand_state: rs, total_wait: state.total_wait + wait}

        {:ok, state, forward ++ [{:delay, service_ticks, state.id, {:depart, next_job}}]}

      {:empty, _} ->
        {:ok, %{state | busy: state.busy - 1}, forward}
    end
  end

  @impl true
  def statistics(state) do
    n = state.departures

    %{
      arrivals: state.arrivals,
      departures: n,
      mean_wait: if(n > 0, do: state.total_wait / n, else: 0.0),
      queue_length: :queue.len(state.queue)
    }
  end

  defp sample_service(%{service_mean: mean, rand_state: rs}) do
    {u, rs} = :rand.uniform_s(rs)
    {max(1, round(-mean * :math.log(u))), rs}
  end

  @doc """
  Build a diasca-mode factory. Returns `{entities, initial_events}`.

  Generates `num_stages` × `machines_per_stage` individual machine entities
  (not capacity-based — each machine is a separate entity for maximum
  parallelism). Plus a source that sends arrivals at every tick.
  """
  def build(opts \\ []) do
    num_stages = opts[:num_stages] || 5
    machines = opts[:machines_per_stage] || 10
    service_mean = opts[:service_mean] || 3.0
    seed = opts[:seed] || 42
    arrival_ticks = opts[:arrival_every] || 1

    # Each machine is a separate entity for parallelism
    # Within a stage, a load-balancer entity distributes to machines
    stage_entities =
      for s <- 0..(num_stages - 1), m <- 0..(machines - 1) do
        id = :"s#{s}_m#{m}"
        next_lb = if s < num_stages - 1, do: :"lb_#{s + 1}", else: nil

        {id, __MODULE__,
         %{
           id: id,
           capacity: 1,
           next_stage: next_lb,
           service_mean: service_mean,
           seed: seed + s * 1000 + m
         }}
      end

    # Load balancers — round-robin to machines in their stage
    lb_entities =
      for s <- 0..(num_stages - 1) do
        id = :"lb_#{s}"
        machine_ids = for m <- 0..(machines - 1), do: :"s#{s}_m#{m}"
        {id, Sim.Bench.LoadBalancer, %{id: id, targets: machine_ids, seed: seed + s * 10_000}}
      end

    # Source — generates arrivals every N ticks to first load balancer
    source = {
      :source,
      Sim.Bench.DiascaSource,
      %{id: :source, target: :lb_0, arrival_every: arrival_ticks, seed: seed + 99_999}
    }

    entities = [source | lb_entities ++ stage_entities]
    initial_events = [{0, :source, :generate}]

    total_machines = num_stages * machines
    {entities, initial_events, total_machines}
  end
end

defmodule Sim.Bench.LoadBalancer do
  @moduledoc "Round-robin load balancer for diasca factory."
  @behaviour Sim.Entity

  defstruct [:id, :targets, index: 0, forwarded: 0]

  @impl true
  def init(config) do
    targets = List.to_tuple(config.targets)
    {:ok, %__MODULE__{id: config.id, targets: targets}}
  end

  @impl true
  def handle_event({:arrive, job_id, enqueue_tick}, _clock, state) do
    target = elem(state.targets, state.index)
    next_idx = rem(state.index + 1, tuple_size(state.targets))

    {:ok, %{state | index: next_idx, forwarded: state.forwarded + 1},
     [{:same_tick, target, {:arrive, job_id, enqueue_tick}}]}
  end

  @impl true
  def statistics(state), do: %{forwarded: state.forwarded}
end

defmodule Sim.Bench.DiascaSource do
  @moduledoc "Periodic source for diasca mode. Generates a batch of arrivals every N ticks."
  @behaviour Sim.Entity

  defstruct [:id, :target, :arrival_every, :rand_state, count: 0, batch_size: 10]

  @impl true
  def init(config) do
    seed = config[:seed] || 42

    {:ok,
     %__MODULE__{
       id: config.id,
       target: config.target,
       arrival_every: config[:arrival_every] || 1,
       batch_size: config[:batch_size] || 10,
       rand_state: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
     }}
  end

  @impl true
  def handle_event(:generate, {tick, _diasca}, state) do
    # Generate a batch of arrivals
    arrivals =
      for i <- 1..state.batch_size do
        job_id = state.count + i
        {:same_tick, state.target, {:arrive, job_id, tick}}
      end

    # Schedule next generation
    next = {:delay, state.arrival_every, state.id, :generate}

    {:ok, %{state | count: state.count + state.batch_size}, [next | arrivals]}
  end

  @impl true
  def statistics(state), do: %{total_generated: state.count}
end
