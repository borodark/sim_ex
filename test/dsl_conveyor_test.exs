defmodule Sim.DSL.ConveyorTest do
  use ExUnit.Case

  # ============================================================
  # SimpleBelt — basic conveyor with ample capacity
  # ============================================================

  defmodule SimpleBelt do
    use Sim.DSL

    model :simple_belt do
      conveyor(:belt, length: 100, speed: 10, capacity: 50)
      resource(:machine, capacity: 1)

      process :part do
        arrive(every: exponential(5.0))
        transport(:belt)
        seize(:machine)
        hold(exponential(3.0))
        release(:machine)
        depart
      end
    end
  end

  # ============================================================
  # NarrowBelt — capacity 2 forces queuing
  # ============================================================

  defmodule NarrowBelt do
    use Sim.DSL

    model :narrow_belt do
      conveyor(:belt, length: 50, speed: 5, capacity: 2)
      resource(:machine, capacity: 1)

      process :part do
        arrive(every: exponential(2.0))
        transport(:belt)
        seize(:machine)
        hold(exponential(3.0))
        release(:machine)
        depart
      end
    end
  end

  # ============================================================
  # DualBelt — two conveyors with a machine in between
  # ============================================================

  defmodule DualBelt do
    use Sim.DSL

    model :dual_belt do
      conveyor(:belt_a, length: 50, speed: 10, capacity: 10)
      conveyor(:belt_b, length: 80, speed: 5, capacity: 10)
      resource(:machine, capacity: 1)

      process :part do
        arrive(every: exponential(5.0))
        transport(:belt_a)
        seize(:machine)
        hold(exponential(3.0))
        release(:machine)
        transport(:belt_b)
        depart
      end
    end
  end

  describe "SimpleBelt" do
    test "compiles and runs: parts complete, belt and machine active" do
      {:ok, result} = SimpleBelt.run(stop_time: 10_000.0, seed: 42)

      part_stats = result.stats[:part]
      belt_stats = result.stats[:belt]
      machine_stats = result.stats[:machine]

      assert part_stats.completed > 0
      assert belt_stats.completed > 0
      assert machine_stats.grants > 0
    end

    test "transit time equals length/speed" do
      {:ok, result} = SimpleBelt.run(stop_time: 10_000.0, seed: 42)

      belt_stats = result.stats[:belt]
      # length=100, speed=10 -> transit=10.0
      assert_in_delta belt_stats.mean_transit, 10.0, 0.01
    end

    test "determinism: same seed, same result" do
      {:ok, r1} = SimpleBelt.run(stop_time: 5_000.0, seed: 42)
      {:ok, r2} = SimpleBelt.run(stop_time: 5_000.0, seed: 42)

      assert r1.stats[:part].completed == r2.stats[:part].completed
      assert r1.stats[:belt].completed == r2.stats[:belt].completed
    end
  end

  describe "NarrowBelt" do
    test "parts complete despite capacity 2 blocking" do
      {:ok, result} = NarrowBelt.run(stop_time: 10_000.0, seed: 42)

      part_stats = result.stats[:part]
      belt_stats = result.stats[:belt]

      assert part_stats.completed > 0
      assert belt_stats.completed > 0
      # With capacity 2 and mean interarrival 2.0, queue should build up
      # Belt transit = 50/5 = 10.0 time units
      assert_in_delta belt_stats.mean_transit, 10.0, 0.01
    end
  end

  describe "DualBelt" do
    test "both belts complete, belt_b slower than belt_a" do
      {:ok, result} = DualBelt.run(stop_time: 10_000.0, seed: 42)

      belt_a = result.stats[:belt_a]
      belt_b = result.stats[:belt_b]

      assert belt_a.completed > 0
      assert belt_b.completed > 0

      # belt_a: 50/10 = 5.0, belt_b: 80/5 = 16.0
      assert_in_delta belt_a.mean_transit, 5.0, 0.01
      assert_in_delta belt_b.mean_transit, 16.0, 0.01
    end
  end

  describe "flow conservation" do
    test "arrivals = completed + in_progress" do
      {:ok, result} = SimpleBelt.run(stop_time: 5_000.0, seed: 42)

      arrivals = result.stats[:part_source].total_arrivals
      completed = result.stats[:part].completed
      in_progress = result.stats[:part].in_progress
      # Every arrival is either completed or still somewhere in the system
      assert arrivals == completed + in_progress
    end
  end
end
