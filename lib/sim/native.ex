defmodule Sim.Native do
  @moduledoc false
  use Rustler, otp_app: :sim_ex, crate: "sim_nif"

  def run_simulation(
        _process_steps,
        _resource_caps,
        _arrival_means,
        _stop_tick,
        _seed,
        _batch_size
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
