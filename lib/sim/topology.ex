defmodule Sim.Topology do
  @moduledoc """
  ETS-based shared state for simulation topology.

  Inspired by InterSCSimulator's pattern: street capacities, occupancy
  counts, and routing tables live in ETS — not in entity processes.
  Entities read freely (concurrent reads are free on ETS), write rarely.

  This avoids the "actor per link" bottleneck: a network of 100K streets
  doesn't need 100K processes, just 100K rows in ETS.

  ## Usage

      {:ok, topo} = Sim.Topology.start_link(name: :network)
      Sim.Topology.put(:network, {:street, "Main St"}, %{capacity: 40, occupancy: 0, speed: 50.0})
      Sim.Topology.get(:network, {:street, "Main St"})
      Sim.Topology.update(:network, {:street, "Main St"}, :occupancy, &(&1 + 1))
  """

  use GenServer

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Store a key-value pair in the topology."
  def put(server \\ __MODULE__, key, value) do
    GenServer.call(server, {:put, key, value})
  end

  @doc "Bulk load topology data."
  def put_many(server \\ __MODULE__, entries) do
    GenServer.call(server, {:put_many, entries})
  end

  @doc "Read a value. Returns `nil` if not found."
  def get(server \\ __MODULE__, key) do
    GenServer.call(server, {:get, key})
  end

  @doc "Update a single field within a stored map."
  def update(server \\ __MODULE__, key, field, fun) do
    GenServer.call(server, {:update, key, field, fun})
  end

  @doc "Read directly from ETS (no GenServer call — use for hot-path reads)."
  def read(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @doc "Get the underlying ETS table reference for direct reads."
  def table(server \\ __MODULE__) do
    GenServer.call(server, :table)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    table = :ets.new(opts[:name] || :sim_topology, [:set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(state.table, {key, value})
    {:reply, :ok, state}
  end

  def handle_call({:put_many, entries}, _from, state) do
    rows = Enum.map(entries, fn {key, value} -> {key, value} end)
    :ets.insert(state.table, rows)
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    value =
      case :ets.lookup(state.table, key) do
        [{^key, v}] -> v
        [] -> nil
      end

    {:reply, value, state}
  end

  def handle_call({:update, key, field, fun}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, value}] when is_map(value) ->
        new_value = Map.update!(value, field, fun)
        :ets.insert(state.table, {key, new_value})
        {:reply, {:ok, new_value}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:table, _from, state) do
    {:reply, state.table, state}
  end
end
