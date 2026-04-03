defmodule Sim.Bench.DiascaPhold do
  @moduledoc """
  PHOLD entity for tick-diasca mode benchmarking.
  Returns `{:delay, ...}` events instead of float timestamps.
  """

  @behaviour Sim.Entity

  defstruct [:id, :num_lps, :remote_fraction, :mean_delay, :rand_state, events_handled: 0]

  @impl true
  def init(config) do
    seed = config[:seed] || config.id
    seed_val = if is_integer(seed), do: seed, else: :erlang.phash2(seed)

    {:ok,
     %__MODULE__{
       id: config.id,
       num_lps: config.num_lps,
       remote_fraction: config[:remote_fraction] || 0.25,
       mean_delay: config[:mean_delay] || 1.0,
       rand_state: :rand.seed(:exsss, {seed_val, seed_val * 7 + 1, seed_val * 13 + 3})
     }}
  end

  @impl true
  def handle_event(:ping, {_tick, _diasca}, state) do
    state = %{state | events_handled: state.events_handled + 1}

    {u, rs} = :rand.uniform_s(state.rand_state)
    delay = max(1, round(-state.mean_delay * :math.log(u)))

    {u2, rs} = :rand.uniform_s(rs)

    {target, rs} =
      if u2 < state.remote_fraction do
        {u3, rs} = :rand.uniform_s(rs)
        other = trunc(u3 * state.num_lps)
        other = if other == state.id, do: rem(other + 1, state.num_lps), else: other
        {other, rs}
      else
        {state.id, rs}
      end

    {:ok, %{state | rand_state: rs}, [{:delay, delay, target, :ping}]}
  end

  @impl true
  def statistics(state), do: %{events_handled: state.events_handled}
end
