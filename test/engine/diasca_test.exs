defmodule Sim.Engine.DiascaTest do
  use ExUnit.Case

  # -- Test entities for diasca mode --

  defmodule Relay do
    @moduledoc "Receives :ping, forwards :pong to target at same tick (D+1)."
    @behaviour Sim.Entity

    def init(config), do: {:ok, %{id: config.id, target: config[:target], log: []}}

    def handle_event(:ping, {tick, diasca}, state) do
      state = %{state | log: [{:received_ping, tick, diasca} | state.log]}

      if state.target do
        {:ok, state, [{:same_tick, state.target, :pong}]}
      else
        {:ok, state, []}
      end
    end

    def handle_event(:pong, {tick, diasca}, state) do
      # Relay also forwards pong to target (as :pong) for cascade testing
      if state.target do
        {:ok, %{state | log: [{:received_pong, tick, diasca} | state.log]},
         [{:same_tick, state.target, :pong}]}
      else
        {:ok, %{state | log: [{:received_pong, tick, diasca} | state.log]}, []}
      end
    end

    def handle_event({:ping_and_schedule, future_tick}, {tick, diasca}, state) do
      state = %{state | log: [{:ping_schedule, tick, diasca} | state.log]}

      events = [
        {:same_tick, state.target, :pong},
        {:tick, future_tick, state.id, :ping}
      ]

      {:ok, state, events}
    end

    def handle_event({:ping_delay, delta}, {tick, diasca}, state) do
      state = %{state | log: [{:ping_delay, tick, diasca} | state.log]}
      {:ok, state, [{:delay, delta, state.id, :ping}]}
    end

    def statistics(state), do: %{log: Enum.reverse(state.log)}
  end

  defmodule Counter do
    @moduledoc "Counts events, no output."
    @behaviour Sim.Entity

    def init(_), do: {:ok, %{count: 0, ticks_seen: []}}

    def handle_event(_event, {tick, diasca}, state) do
      {:ok, %{state | count: state.count + 1, ticks_seen: [{tick, diasca} | state.ticks_seen]},
       []}
    end

    def statistics(state) do
      %{count: state.count, ticks_seen: Enum.reverse(state.ticks_seen)}
    end
  end

  describe "causality" do
    test "same-tick event arrives at diasca + 1" do
      {:ok, result} =
        Sim.run(
          mode: :diasca,
          entities: [
            {:a, Relay, %{id: :a, target: :b}},
            {:b, Relay, %{id: :b, target: nil}}
          ],
          initial_events: [{0, :a, :ping}],
          stop_tick: 10
        )

      # A receives ping at (0, 0), sends pong to B
      # B receives pong at (0, 1)
      a_log = result.stats[:a].log
      b_log = result.stats[:b].log

      assert [{:received_ping, 0, 0}] = a_log
      assert [{:received_pong, 0, 1}] = b_log
    end

    test "three-hop cascade within one tick" do
      {:ok, result} =
        Sim.run(
          mode: :diasca,
          entities: [
            {:a, Relay, %{id: :a, target: :b}},
            {:b, Relay, %{id: :b, target: :c}},
            {:c, Relay, %{id: :c, target: nil}}
          ],
          initial_events: [{0, :a, :ping}],
          stop_tick: 10
        )

      a_log = result.stats[:a].log
      b_log = result.stats[:b].log
      c_log = result.stats[:c].log

      # A at (0,0), B gets pong at (0,1), B forwards pong to C at (0,2)
      assert [{:received_ping, 0, 0}] = a_log
      assert [{:received_pong, 0, 1}] = b_log
      assert [{:received_pong, 0, 2}] = c_log
    end
  end

  describe "quiescence and tick advance" do
    test "tick advances when no same-tick events remain" do
      {:ok, result} =
        Sim.run(
          mode: :diasca,
          entities: [
            {:c, Counter, %{}}
          ],
          initial_events: [{0, :c, :one}, {5, :c, :two}, {10, :c, :three}],
          stop_tick: 100
        )

      assert result.stats[:c].count == 3
      assert result.stats[:c].ticks_seen == [{0, 0}, {5, 0}, {10, 0}]
      assert result.tick == 10
    end

    test "diascas process before next tick" do
      # A at tick 0 sends to B (same tick). B also gets event at tick 5.
      # Diasca (0,1) must process before (5,0).
      {:ok, result} =
        Sim.run(
          mode: :diasca,
          entities: [
            {:a, Relay, %{id: :a, target: :b}},
            {:b, Counter, %{}}
          ],
          initial_events: [{0, :a, :ping}, {5, :b, :later}],
          stop_tick: 100
        )

      ticks = result.stats[:b].ticks_seen
      # B sees: (0, 1) from relay, then (5, 0) from initial
      assert [{0, 1}, {5, 0}] = ticks
    end
  end

  describe "future tick scheduling" do
    test "{:tick, future, target, event} lands at (future, 0)" do
      {:ok, result} =
        Sim.run(
          mode: :diasca,
          entities: [
            {:a, Relay, %{id: :a, target: :b}},
            {:b, Counter, %{}}
          ],
          initial_events: [{0, :a, {:ping_and_schedule, 10}}],
          stop_tick: 100
        )

      # A at (0,0) sends pong to B at (0,1) AND schedules ping to self at (10,0)
      # At (10,0), A handles :ping and sends pong to B at (10,1)
      # B sees (0,1) and (10,1)
      b_ticks = result.stats[:b].ticks_seen
      assert [{0, 1}, {10, 1}] = b_ticks

      a_log = result.stats[:a].log
      assert {:ping_schedule, 0, 0} = hd(a_log)
      # Second event is the self-scheduled ping at tick 10
      assert {:received_ping, 10, 0} = Enum.at(a_log, 1)
    end
  end

  describe "delay scheduling" do
    test "{:delay, delta, target, event} lands at (tick + delta, 0)" do
      {:ok, result} =
        Sim.run(
          mode: :diasca,
          entities: [
            {:a, Relay, %{id: :a, target: nil}}
          ],
          initial_events: [{3, :a, {:ping_delay, 7}}],
          stop_tick: 100
        )

      a_log = result.stats[:a].log
      # First: ping_delay at (3, 0). Second: ping at (10, 0).
      assert [{:ping_delay, 3, 0}, {:received_ping, 10, 0}] = a_log
    end
  end

  describe "stop tick" do
    test "engine stops at stop_tick" do
      {:ok, result} =
        Sim.run(
          mode: :diasca,
          entities: [
            {:c, Counter, %{}}
          ],
          initial_events: [{0, :c, :a}, {5, :c, :b}, {10, :c, :c}, {15, :c, :d}],
          stop_tick: 12
        )

      # Events at tick 0, 5, 10 process. Tick 15 > 12, stops.
      assert result.stats[:c].count == 3
      assert result.tick == 10
    end
  end

  describe "determinism" do
    test "same initial events produce same result" do
      run = fn ->
        Sim.run(
          mode: :diasca,
          entities: [
            {:a, Relay, %{id: :a, target: :b}},
            {:b, Relay, %{id: :b, target: :c}},
            {:c, Counter, %{}}
          ],
          initial_events: [{0, :a, :ping}, {1, :a, :ping}, {2, :a, :ping}],
          stop_tick: 10
        )
      end

      {:ok, r1} = run.()
      {:ok, r2} = run.()

      assert r1.events == r2.events
      assert r1.stats[:c].ticks_seen == r2.stats[:c].ticks_seen
    end
  end
end
