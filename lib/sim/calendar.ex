defmodule Sim.Calendar do
  @moduledoc """
  Event calendar — priority queue of future events ordered by time.

  Uses `:gb_trees` for O(log n) insert and O(log n) pop-minimum.
  Tie-breaking: events at the same time are ordered by insertion
  sequence number (FIFO within a tick).

  ## Why not a heap?

  `:gb_trees` is built into OTP, battle-tested, and supports
  `smallest/1` + `delete/2` atomically. For DES workloads
  (millions of events, frequent insert + pop-min), it matches
  or beats Erlang heap implementations.
  """

  use GenServer

  defstruct tree: :gb_trees.empty(), seq: 0

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Schedule an event at `time` for `target` entity."
  def push(server \\ __MODULE__, time, target, event) do
    GenServer.cast(server, {:push, time, target, event})
  end

  @doc "Schedule multiple events at once (batch insert)."
  def push_many(server \\ __MODULE__, events) do
    GenServer.cast(server, {:push_many, events})
  end

  @doc "Pop the earliest event. Returns `{:ok, {time, target, event}}` or `:empty`."
  def pop(server \\ __MODULE__) do
    GenServer.call(server, :pop)
  end

  @doc "Number of pending events."
  def size(server \\ __MODULE__) do
    GenServer.call(server, :size)
  end

  @doc "Peek at earliest event time without removing."
  def peek_time(server \\ __MODULE__) do
    GenServer.call(server, :peek_time)
  end

  # --- Server ---

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:push, time, target, event}, state) do
    key = {time, state.seq}
    tree = :gb_trees.insert(key, {target, event}, state.tree)
    {:noreply, %{state | tree: tree, seq: state.seq + 1}}
  end

  def handle_cast({:push_many, events}, state) do
    {tree, seq} =
      Enum.reduce(events, {state.tree, state.seq}, fn {time, target, event}, {tree, seq} ->
        key = {time, seq}
        {:gb_trees.insert(key, {target, event}, tree), seq + 1}
      end)

    {:noreply, %{state | tree: tree, seq: seq}}
  end

  @impl true
  def handle_call(:pop, _from, state) do
    case :gb_trees.is_empty(state.tree) do
      true ->
        {:reply, :empty, state}

      false ->
        {{time, _seq}, {target, event}, tree} = :gb_trees.take_smallest(state.tree)
        {:reply, {:ok, {time, target, event}}, %{state | tree: tree}}
    end
  end

  def handle_call(:size, _from, state) do
    {:reply, :gb_trees.size(state.tree), state}
  end

  def handle_call(:peek_time, _from, state) do
    case :gb_trees.is_empty(state.tree) do
      true ->
        {:reply, :empty, state}

      false ->
        {{time, _seq}, _val} = :gb_trees.smallest(state.tree)
        {:reply, {:ok, time}, state}
    end
  end
end
