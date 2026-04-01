defmodule Sim.EntityManager do
  @moduledoc """
  Manages simulation entities — registry + dispatch.

  Two modes:
  - **Process mode**: each entity is a GenServer (scales to millions via BEAM).
    Use for large models, distributed simulation, fault tolerance.
  - **Inline mode**: entities are maps in an ETS table, dispatched synchronously.
    Use for maximum single-node throughput (no message passing overhead).

  Default is inline mode. Process mode via `mode: :process` option.

  Inspired by InterSCSimulator's CarManager: entities are activated lazily
  by tick, not all spawned at t=0.
  """

  use GenServer

  defstruct [:mode, :table, entities: %{}, modules: %{}]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Register an entity.

  - `id` — unique entity identifier
  - `module` — module implementing `Sim.Entity` behaviour
  - `config` — passed to `module.init/1`
  """
  def register(server \\ __MODULE__, id, module, config) do
    GenServer.call(server, {:register, id, module, config})
  end

  @doc "Dispatch an event to an entity. Returns list of new events."
  def dispatch(server \\ __MODULE__, target, event, time) do
    GenServer.call(server, {:dispatch, target, event, time}, :infinity)
  end

  @doc "Get statistics from all entities."
  def all_statistics(server \\ __MODULE__) do
    GenServer.call(server, :all_statistics)
  end

  @doc "Get state of a specific entity."
  def get_state(server \\ __MODULE__, id) do
    GenServer.call(server, {:get_state, id})
  end

  # --- Server (inline mode) ---

  @impl true
  def init(opts) do
    mode = opts[:mode] || :inline
    {:ok, %__MODULE__{mode: mode}}
  end

  @impl true
  def handle_call({:register, id, module, config}, _from, %{mode: :inline} = state) do
    {:ok, entity_state} = module.init(config)
    entities = Map.put(state.entities, id, entity_state)
    modules = Map.put(state.modules, id, module)
    {:reply, :ok, %{state | entities: entities, modules: modules}}
  end

  def handle_call({:dispatch, target, event, time}, _from, %{mode: :inline} = state) do
    module = Map.fetch!(state.modules, target)
    entity_state = Map.fetch!(state.entities, target)

    {:ok, new_state, new_events} = module.handle_event(event, time, entity_state)

    entities = Map.put(state.entities, target, new_state)
    {:reply, new_events, %{state | entities: entities}}
  end

  def handle_call(:all_statistics, _from, %{mode: :inline} = state) do
    stats =
      Enum.reduce(state.entities, %{}, fn {id, entity_state}, acc ->
        module = Map.fetch!(state.modules, id)

        if function_exported?(module, :statistics, 1) do
          Map.put(acc, id, module.statistics(entity_state))
        else
          acc
        end
      end)

    {:reply, stats, state}
  end

  def handle_call({:get_state, id}, _from, %{mode: :inline} = state) do
    {:reply, Map.get(state.entities, id), state}
  end
end
