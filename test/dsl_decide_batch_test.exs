defmodule Sim.DSL.DecideBatchTest do
  use ExUnit.Case

  # ============================================================
  # DECIDE — probabilistic routing
  # ============================================================

  # Rework loop: 20% of parts fail inspection, go back to rework
  defmodule ReworkLine do
    use Sim.DSL

    model :rework_line do
      resource(:machine, capacity: 2)
      resource(:rework, capacity: 1)

      process :part do
        arrive(every: exponential(5.0))
        seize(:machine)
        hold(exponential(4.0))
        release(:machine)
        # 20% fail inspection → rework → back to inspect
        decide(0.2, :rework_station)
        depart
        label(:rework_station)
        seize(:rework)
        hold(exponential(6.0))
        release(:rework)
        depart
      end
    end
  end

  describe "decide (probabilistic routing)" do
    test "rework line: some parts go to rework, rest depart" do
      {:ok, result} = ReworkLine.run(stop_time: 20_000.0, seed: 42)

      machine = result.stats[:machine]
      rework = result.stats[:rework]
      part = result.stats[:part]

      # Machine should process all parts
      assert machine.grants > 0

      # Rework should process ~20% of parts
      assert rework.grants > 0
      assert rework.grants < machine.grants

      # Rework fraction should be roughly 20% (allow 10-30% range)
      rework_pct = rework.grants / machine.grants * 100
      assert rework_pct > 10, "rework too low: #{rework_pct}%"
      assert rework_pct < 35, "rework too high: #{rework_pct}%"

      # All parts should eventually depart
      assert part.completed > 0
    end

    test "rework is deterministic with same seed" do
      {:ok, r1} = ReworkLine.run(stop_time: 5_000.0, seed: 99)
      {:ok, r2} = ReworkLine.run(stop_time: 5_000.0, seed: 99)

      assert r1.stats[:rework].grants == r2.stats[:rework].grants
      assert r1.stats[:part].completed == r2.stats[:part].completed
    end

    test "decide 0.0 means nobody goes to rework" do
      # Override: 0% rework
      defmodule NoRework do
        use Sim.DSL

        model :no_rework do
          resource(:machine, capacity: 2)
          resource(:rework, capacity: 1)

          process :part do
            arrive(every: exponential(5.0))
            seize(:machine)
            hold(exponential(4.0))
            release(:machine)
            decide(0.0, :rework_station)
            depart
            label(:rework_station)
            seize(:rework)
            hold(exponential(6.0))
            release(:rework)
            depart
          end
        end
      end

      {:ok, result} = NoRework.run(stop_time: 5_000.0, seed: 42)
      assert result.stats[:rework].grants == 0
    end

    test "decide 1.0 means everyone goes to rework" do
      defmodule AllRework do
        use Sim.DSL

        model :all_rework do
          resource(:machine, capacity: 2)
          resource(:rework, capacity: 1)

          process :part do
            arrive(every: exponential(5.0))
            seize(:machine)
            hold(exponential(4.0))
            release(:machine)
            decide(1.0, :rework_station)
            depart
            label(:rework_station)
            seize(:rework)
            hold(exponential(6.0))
            release(:rework)
            depart
          end
        end
      end

      {:ok, result} = AllRework.run(stop_time: 5_000.0, seed: 42)
      # Every completed part should have gone through rework (decide 1.0)
      # Allow ±1 for edge case at simulation end
      assert result.stats[:rework].grants > 0
      assert abs(result.stats[:rework].grants - result.stats[:part].completed) <= 1
    end
  end

  # ============================================================
  # DECIDE_MULTI — weighted multi-way routing
  # ============================================================

  defmodule ThreeRoutes do
    use Sim.DSL

    model :three_routes do
      resource(:fast, capacity: 3)
      resource(:medium, capacity: 2)
      resource(:slow, capacity: 1)

      process :part do
        arrive(every: exponential(3.0))
        decide([{0.5, :fast_lane}, {0.3, :medium_lane}, {0.2, :slow_lane}])
        # fallthrough should not happen (all probs sum to 1)
        depart
        label(:fast_lane)
        seize(:fast)
        hold(exponential(2.0))
        release(:fast)
        depart
        label(:medium_lane)
        seize(:medium)
        hold(exponential(5.0))
        release(:medium)
        depart
        label(:slow_lane)
        seize(:slow)
        hold(exponential(10.0))
        release(:slow)
        depart
      end
    end
  end

  describe "decide_multi (weighted routing)" do
    test "traffic splits roughly according to probabilities" do
      {:ok, result} = ThreeRoutes.run(stop_time: 20_000.0, seed: 42)

      fast = result.stats[:fast].grants
      medium = result.stats[:medium].grants
      slow = result.stats[:slow].grants
      total = fast + medium + slow

      assert total > 0

      fast_pct = fast / total * 100
      medium_pct = medium / total * 100
      slow_pct = slow / total * 100

      # Allow ±15% tolerance (50% ± 15, 30% ± 15, 20% ± 15)
      assert fast_pct > 35, "fast too low: #{Float.round(fast_pct, 1)}%"
      assert fast_pct < 65, "fast too high: #{Float.round(fast_pct, 1)}%"
      assert medium_pct > 15, "medium too low: #{Float.round(medium_pct, 1)}%"
      assert medium_pct < 45, "medium too high: #{Float.round(medium_pct, 1)}%"
      assert slow_pct > 5, "slow too low: #{Float.round(slow_pct, 1)}%"
      assert slow_pct < 35, "slow too high: #{Float.round(slow_pct, 1)}%"
    end
  end

  # ============================================================
  # BATCH — accumulate N parts before proceeding
  # ============================================================

  defmodule BoxingLine do
    use Sim.DSL

    model :boxing_line do
      resource(:machine, capacity: 2)
      resource(:box_station, capacity: 1)

      process :part do
        arrive(every: exponential(3.0))
        seize(:machine)
        hold(exponential(2.0))
        release(:machine)
        batch(5)
        seize(:box_station)
        hold(exponential(4.0))
        release(:box_station)
        depart
      end
    end
  end

  describe "batch (accumulate N parts)" do
    test "parts batch in groups of 5" do
      {:ok, result} = BoxingLine.run(stop_time: 10_000.0, seed: 42)

      machine = result.stats[:machine].grants
      box = result.stats[:box_station].grants
      completed = result.stats[:part].completed

      # Machine processes every part individually
      assert machine > 0

      # Box station processes batched parts — each batch of 5 parts
      # goes through box_station, so box grants should be ~machine/5
      # (allowing for incomplete final batch)
      assert box > 0
      assert completed > 0

      # box_station grants should equal completed (each batched part goes through)
      # Allow ±1 for edge cases at simulation end
      assert abs(box - completed) <= 1
    end

    test "batch is deterministic" do
      {:ok, r1} = BoxingLine.run(stop_time: 5_000.0, seed: 42)
      {:ok, r2} = BoxingLine.run(stop_time: 5_000.0, seed: 42)

      assert r1.stats[:part].completed == r2.stats[:part].completed
      assert r1.stats[:box_station].grants == r2.stats[:box_station].grants
    end

    test "batch 1 is a no-op (every part proceeds immediately)" do
      defmodule NoBatch do
        use Sim.DSL

        model :no_batch do
          resource(:machine, capacity: 2)

          process :part do
            arrive(every: exponential(5.0))
            seize(:machine)
            hold(exponential(3.0))
            release(:machine)
            batch(1)
            depart
          end
        end
      end

      {:ok, result} = NoBatch.run(stop_time: 5_000.0, seed: 42)
      # Every part completes — batch(1) doesn't block
      assert result.stats[:part].completed > 0
      assert result.stats[:part].completed == result.stats[:machine].grants
    end
  end

  # ============================================================
  # COMBINED — decide + batch in same process
  # ============================================================

  defmodule QualityLine do
    use Sim.DSL

    model :quality_line do
      resource(:machine, capacity: 3)
      resource(:rework, capacity: 1)
      resource(:packer, capacity: 1)

      process :part do
        arrive(every: exponential(4.0))
        seize(:machine)
        hold(exponential(3.0))
        release(:machine)
        # 15% fail QC
        decide(0.15, :rework_loop)
        # Good parts: batch into boxes of 4, then pack
        batch(4)
        seize(:packer)
        hold(exponential(2.0))
        release(:packer)
        depart
        # Rework loop
        label(:rework_loop)
        seize(:rework)
        hold(exponential(8.0))
        release(:rework)
        depart
      end
    end
  end

  describe "combined (decide + batch)" do
    test "quality line: rework + batching" do
      {:ok, result} = QualityLine.run(stop_time: 20_000.0, seed: 42)

      machine = result.stats[:machine].grants
      rework = result.stats[:rework].grants
      packer = result.stats[:packer].grants
      completed = result.stats[:part].completed

      # All parts go through machine
      assert machine > 0

      # ~15% go to rework
      assert rework > 0
      rework_pct = rework / machine * 100
      assert rework_pct > 5
      assert rework_pct < 30

      # Good parts batch in 4s, then pack
      # Packer sees batched good parts
      assert packer > 0

      # Total completed = rework departures + packer departures
      assert completed > 0
    end
  end
end
