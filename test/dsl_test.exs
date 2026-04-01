defmodule Sim.DSLTest do
  use ExUnit.Case

  # -- Define a barbershop model via DSL --
  defmodule Barbershop do
    use Sim.DSL

    model :barbershop do
      resource(:barber, capacity: 1)

      process :customer do
        arrive(every: exponential(18.0))
        seize(:barber)
        hold(exponential(16.0))
        release(:barber)
        depart
      end
    end
  end

  # -- Define a two-server job shop --
  defmodule JobShop do
    use Sim.DSL

    model :job_shop do
      resource(:drill, capacity: 2)
      resource(:lathe, capacity: 1)

      process :part do
        arrive(every: exponential(10.0))
        seize(:drill)
        hold(exponential(8.0))
        release(:drill)
        seize(:lathe)
        hold(exponential(12.0))
        release(:lathe)
        depart
      end
    end
  end

  describe "barbershop (engine mode)" do
    test "runs and produces statistics" do
      {:ok, result} = Barbershop.run(stop_time: 5_000.0, seed: 42)

      customer_stats = result.stats[:customer]
      assert customer_stats.completed > 0
      assert customer_stats.mean_wait >= 0.0
      assert customer_stats.mean_hold > 0.0

      barber_stats = result.stats[:barber]
      assert barber_stats.grants > 0
      assert barber_stats.releases > 0
    end

    test "arrivals roughly match interarrival rate" do
      {:ok, result} = Barbershop.run(stop_time: 10_000.0, seed: 99)

      # With mean interarrival 18, expect ~556 arrivals in 10000 time units
      source_stats = result.stats[:customer_source]
      assert source_stats.total_arrivals > 400
      assert source_stats.total_arrivals < 700
    end

    test "deterministic with same seed" do
      {:ok, r1} = Barbershop.run(stop_time: 2_000.0, seed: 42)
      {:ok, r2} = Barbershop.run(stop_time: 2_000.0, seed: 42)

      assert r1.stats[:customer].completed == r2.stats[:customer].completed
      assert r1.events == r2.events
    end
  end

  describe "barbershop (diasca mode)" do
    test "runs in diasca mode" do
      {:ok, result} = Barbershop.run(mode: :diasca, stop_tick: 5_000, seed: 42)

      customer_stats = result.stats[:customer]
      assert customer_stats.completed > 0
      assert customer_stats.mean_hold > 0.0
    end
  end

  describe "job shop" do
    test "two sequential resources both see traffic" do
      {:ok, result} = JobShop.run(stop_time: 5_000.0, seed: 42)

      drill_stats = result.stats[:drill]
      lathe_stats = result.stats[:lathe]
      part_stats = result.stats[:part]

      assert drill_stats.grants > 0
      assert lathe_stats.grants > 0
      assert part_stats.completed > 0

      # Parts that complete must have passed through both
      assert drill_stats.releases > 0
      assert lathe_stats.releases > 0
    end
  end

  describe "module generation" do
    test "DSL generates entity module" do
      assert Code.ensure_loaded?(Sim.DSLTest.Barbershop.Customer)
    end

    test "generated module implements Sim.Entity" do
      behaviours =
        Sim.DSLTest.Barbershop.Customer.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Sim.Entity in behaviours
    end
  end
end
