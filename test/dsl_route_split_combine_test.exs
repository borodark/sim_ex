defmodule Sim.DSL.RouteSplitCombineTest do
  use ExUnit.Case

  # ============================================================
  # ROUTE — travel delay between stations
  # ============================================================

  defmodule ConveyorLine do
    use Sim.DSL

    model :conveyor_line do
      resource(:station_a, capacity: 2)
      resource(:station_b, capacity: 2)

      process :part do
        arrive(every: exponential(5.0))
        seize(:station_a)
        hold(exponential(3.0))
        release(:station_a)
        route(exponential(2.0))
        seize(:station_b)
        hold(exponential(4.0))
        release(:station_b)
        depart
      end
    end
  end

  describe "route (travel delay)" do
    test "route adds delay between stations" do
      # With route
      {:ok, r_route} = ConveyorLine.run(stop_time: 10_000.0, seed: 42)

      # Without route (direct transfer)
      defmodule DirectLine do
        use Sim.DSL

        model :direct_line do
          resource(:station_a, capacity: 2)
          resource(:station_b, capacity: 2)

          process :part do
            arrive(every: exponential(5.0))
            seize(:station_a)
            hold(exponential(3.0))
            release(:station_a)
            seize(:station_b)
            hold(exponential(4.0))
            release(:station_b)
            depart
          end
        end
      end

      {:ok, r_direct} = DirectLine.run(stop_time: 10_000.0, seed: 42)

      # Route version should have longer mean processing time
      assert r_route.stats[:part].mean_hold > r_direct.stats[:part].mean_hold
      # Both should complete parts
      assert r_route.stats[:part].completed > 0
      assert r_direct.stats[:part].completed > 0
    end

    test "route is deterministic" do
      {:ok, r1} = ConveyorLine.run(stop_time: 5_000.0, seed: 42)
      {:ok, r2} = ConveyorLine.run(stop_time: 5_000.0, seed: 42)

      assert r1.stats[:part].completed == r2.stats[:part].completed
    end
  end

  # ============================================================
  # SPLIT — one part becomes N parts
  # ============================================================

  defmodule KittingLine do
    use Sim.DSL

    model :kitting_line do
      resource(:cutter, capacity: 1)
      resource(:finisher, capacity: 3)

      process :part do
        arrive(every: exponential(10.0))
        seize(:cutter)
        hold(exponential(5.0))
        release(:cutter)
        split(3)
        seize(:finisher)
        hold(exponential(3.0))
        release(:finisher)
        depart
      end
    end
  end

  describe "split (one becomes N)" do
    test "split 3 triples the parts through downstream" do
      {:ok, result} = KittingLine.run(stop_time: 10_000.0, seed: 42)

      cutter = result.stats[:cutter].grants
      finisher = result.stats[:finisher].grants

      # Cutter processes original parts
      assert cutter > 0

      # Finisher should see ~3x the parts (split creates 2 clones + original)
      ratio = finisher / cutter
      assert ratio > 2.5, "expected ~3x, got #{Float.round(ratio, 1)}x"
      assert ratio < 3.5, "expected ~3x, got #{Float.round(ratio, 1)}x"
    end

    test "split is deterministic" do
      {:ok, r1} = KittingLine.run(stop_time: 5_000.0, seed: 42)
      {:ok, r2} = KittingLine.run(stop_time: 5_000.0, seed: 42)

      assert r1.stats[:finisher].grants == r2.stats[:finisher].grants
    end
  end

  # ============================================================
  # COMBINE — N parts merge into 1
  # ============================================================

  defmodule AssemblyLine do
    use Sim.DSL

    model :assembly_line do
      resource(:prep, capacity: 3)
      resource(:assembler, capacity: 1)

      process :part do
        arrive(every: exponential(3.0))
        seize(:prep)
        hold(exponential(2.0))
        release(:prep)
        combine(4)
        seize(:assembler)
        hold(exponential(5.0))
        release(:assembler)
        depart
      end
    end
  end

  describe "combine (N become 1)" do
    test "combine 4 reduces parts through downstream by ~4x" do
      {:ok, result} = AssemblyLine.run(stop_time: 20_000.0, seed: 42)

      prep = result.stats[:prep].grants
      assembler = result.stats[:assembler].grants

      # Prep processes every part
      assert prep > 0

      # Assembler sees ~1/4 of parts (combine consumes 3, passes 1)
      ratio = prep / max(assembler, 1)
      assert ratio > 3.0, "expected ~4x reduction, got #{Float.round(ratio, 1)}x"
      assert ratio < 5.5, "expected ~4x reduction, got #{Float.round(ratio, 1)}x"
    end

    test "combine is deterministic" do
      {:ok, r1} = AssemblyLine.run(stop_time: 5_000.0, seed: 42)
      {:ok, r2} = AssemblyLine.run(stop_time: 5_000.0, seed: 42)

      assert r1.stats[:assembler].grants == r2.stats[:assembler].grants
    end
  end

  # ============================================================
  # NON-STATIONARY ARRIVALS — rate changes by time
  # ============================================================

  defmodule RushHourShop do
    use Sim.DSL

    model :rush_hour do
      resource(:server, capacity: 2)

      process :customer do
        arrive(
          schedule: [
            {0..299, {:exponential, 10.0}},
            {300..599, {:exponential, 2.0}},
            {600..899, {:exponential, 10.0}}
          ]
        )

        seize(:server)
        hold(exponential(3.0))
        release(:server)
        depart
      end
    end
  end

  describe "non-stationary arrivals" do
    test "rush hour generates more arrivals during peak period" do
      {:ok, result} = RushHourShop.run(stop_time: 900.0, seed: 42)

      # Should complete customers
      assert result.stats[:customer].completed > 0

      # Total arrivals should reflect the mixed rate
      # Period 0-300: ~30 arrivals (mean 10)
      # Period 300-600: ~150 arrivals (mean 2)
      # Period 600-900: ~30 arrivals (mean 10)
      # Total: ~210
      total = result.stats[:customer_source].total_arrivals
      assert total > 100, "too few arrivals: #{total}"
      assert total < 400, "too many arrivals: #{total}"
    end

    test "non-stationary is deterministic" do
      {:ok, r1} = RushHourShop.run(stop_time: 900.0, seed: 42)
      {:ok, r2} = RushHourShop.run(stop_time: 900.0, seed: 42)

      assert r1.stats[:customer_source].total_arrivals ==
               r2.stats[:customer_source].total_arrivals
    end
  end

  # ============================================================
  # COMBINED — split + combine (kitting then assembly)
  # ============================================================

  defmodule SplitCombineLine do
    use Sim.DSL

    model :split_combine do
      resource(:cutter, capacity: 1)
      resource(:processor, capacity: 4)
      resource(:assembler, capacity: 1)

      process :part do
        arrive(every: exponential(15.0))
        seize(:cutter)
        hold(exponential(3.0))
        release(:cutter)
        split(4)
        seize(:processor)
        hold(exponential(4.0))
        release(:processor)
        combine(4)
        seize(:assembler)
        hold(exponential(5.0))
        release(:assembler)
        depart
      end
    end
  end

  describe "split + combine pipeline" do
    test "split then combine: cutter=assembler, processor=4x" do
      {:ok, result} = SplitCombineLine.run(stop_time: 20_000.0, seed: 42)

      cutter = result.stats[:cutter].grants
      processor = result.stats[:processor].grants
      assembler = result.stats[:assembler].grants

      assert cutter > 0
      assert processor > 0
      assert assembler > 0

      # Processor sees 4x cutter (split 4)
      split_ratio = processor / cutter
      assert split_ratio > 3.0, "split ratio #{Float.round(split_ratio, 1)}"
      assert split_ratio < 5.0, "split ratio #{Float.round(split_ratio, 1)}"

      # Assembler sees ~1/4 of processor (combine 4)
      combine_ratio = processor / max(assembler, 1)
      assert combine_ratio > 3.0, "combine ratio #{Float.round(combine_ratio, 1)}"
    end
  end
end
