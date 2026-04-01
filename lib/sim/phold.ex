defmodule Sim.PHOLD do
  @moduledoc """
  PHOLD (Parallel HOLD) benchmark entity.

  The standard synthetic benchmark for discrete-event simulation engines.
  Each logical process (LP) receives an event, does minimal work, and
  sends a new event to a random LP with exponential timestamp increment.

  ## Parameters

  - `num_lps` — total number of logical processes
  - `remote_fraction` — probability of sending to another LP (0.0-1.0)
  - `lookahead` — minimum timestamp increment (reduces rollbacks)
  - `mean_delay` — mean of exponential delay added to lookahead

  ## Usage

      Sim.PHOLD.run(num_lps: 10_000, events_per_lp: 16,
        remote_fraction: 0.25, stop_time: 100.0)

  ## Reference

  PHOLD stresses infrastructure, not computation. Each event does ~1
  memory access. What matters: event queue throughput, message passing
  overhead, GC pressure. ROSS achieves 504B events/sec on 1.9M cores.
  """

  @behaviour Sim.Entity

  defstruct [
    :id,
    :num_lps,
    :remote_fraction,
    :lookahead,
    :mean_delay,
    :rand_state,
    events_handled: 0
  ]

  @impl true
  def init(config) do
    seed = config[:seed] || config.id
    seed_val = if is_integer(seed), do: seed, else: :erlang.phash2(seed)

    {:ok,
     %__MODULE__{
       id: config.id,
       num_lps: config.num_lps,
       remote_fraction: config[:remote_fraction] || 0.25,
       lookahead: config[:lookahead] || 0.0,
       mean_delay: config[:mean_delay] || 1.0,
       rand_state: :rand.seed(:exsss, {seed_val, seed_val * 7 + 1, seed_val * 13 + 3})
     }}
  end

  @impl true
  def handle_event(:ping, clock, state) do
    state = %{state | events_handled: state.events_handled + 1}

    # Sample delay
    {u, rs} = :rand.uniform_s(state.rand_state)
    delay = state.lookahead + -state.mean_delay * :math.log(u)

    # Pick target: self or remote
    {u2, rs} = :rand.uniform_s(rs)

    {target, rs} =
      if u2 < state.remote_fraction do
        # Remote: pick random LP that isn't self
        {u3, rs} = :rand.uniform_s(rs)
        other = trunc(u3 * state.num_lps)
        other = if other == state.id, do: rem(other + 1, state.num_lps), else: other
        {other, rs}
      else
        {state.id, rs}
      end

    events = [{clock + delay, target, :ping}]
    {:ok, %{state | rand_state: rs}, events}
  end

  @impl true
  def statistics(state) do
    %{events_handled: state.events_handled}
  end

  # --- Convenience runner ---

  @doc """
  Run PHOLD benchmark with given parameters.

  Returns `%{events_per_second: float, total_events: int, wall_time_ms: int}`.
  """
  def run(opts \\ []) do
    num_lps = opts[:num_lps] || 1_000
    events_per_lp = opts[:events_per_lp] || 16
    remote_fraction = opts[:remote_fraction] || 0.25
    stop_time = opts[:stop_time] || 100.0
    lookahead = opts[:lookahead] || 0.0
    mean_delay = opts[:mean_delay] || 1.0

    entities =
      for lp <- 0..(num_lps - 1) do
        {lp, Sim.PHOLD,
         %{
           id: lp,
           num_lps: num_lps,
           remote_fraction: remote_fraction,
           lookahead: lookahead,
           mean_delay: mean_delay,
           seed: lp
         }}
      end

    # Seed initial events: events_per_lp per LP at random times
    initial_events =
      for lp <- 0..(num_lps - 1),
          _ <- 1..events_per_lp do
        {0.0, lp, :ping}
      end

    start = System.monotonic_time(:millisecond)

    {:ok, result} =
      Sim.run(
        entities: entities,
        initial_events: initial_events,
        stop_time: stop_time
      )

    wall_ms = System.monotonic_time(:millisecond) - start

    eps = if wall_ms > 0, do: result.events / (wall_ms / 1000.0), else: 0.0

    %{
      events_per_second: eps,
      total_events: result.events,
      wall_time_ms: wall_ms,
      num_lps: num_lps,
      remote_fraction: remote_fraction,
      final_time: result.clock
    }
  end
end
