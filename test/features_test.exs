defmodule Sim.FeaturesTest do
  use ExUnit.Case

  # ============================================================
  # WARM-UP DETECTION
  # ============================================================

  describe "Sim.Warmup" do
    test "detects warm-up in a trending-then-stable series" do
      :rand.seed(:exsss, {42, 42, 42})
      # First 100: strong trend. Next 400: stable around 50.
      warmup = Enum.map(1..100, fn i -> i * 0.5 + :rand.uniform() * 2 end)
      steady = Enum.map(1..400, fn _ -> 50.0 + :rand.uniform() * 2 - 1.0 end)
      observations = warmup ++ steady

      {:ok, truncation} =
        Sim.Warmup.detect(observations, window: 20, threshold: 0.03, min_steady: 5)

      # Truncation should be somewhere in the transition zone
      assert truncation > 20, "truncation too early: #{truncation}"
      assert truncation < 200, "truncation too late: #{truncation}"
    end

    test "no warmup in a stationary series" do
      observations = Enum.map(1..500, fn _ -> 50.0 + :rand.uniform() * 5 - 2.5 end)

      result = Sim.Warmup.detect(observations, window: 20, threshold: 0.03, min_steady: 5)

      case result do
        {:no_warmup, 0} -> assert true
        {:ok, idx} -> assert idx < 50, "detected warmup in stationary series at #{idx}"
      end
    end

    test "truncate returns steady-state observations" do
      warmup = Enum.map(1..50, fn i -> i * 1.0 end)
      steady = Enum.map(1..200, fn _ -> 50.0 + :rand.uniform() * 2 end)
      observations = warmup ++ steady

      {truncated, _idx} =
        Sim.Warmup.truncate(observations, window: 10, threshold: 0.05, min_steady: 3)

      # Truncated should be shorter than original
      assert length(truncated) < length(observations)
      assert length(truncated) > 100
    end

    test "moving_average produces correct window size" do
      observations = Enum.map(1..100, fn i -> i * 1.0 end)
      ma = Sim.Warmup.moving_average(observations, window: 10)

      # 100 - 10 + 1
      assert length(ma) == 91
      # first index is window/2
      assert {5, _val} = hd(ma)
    end

    test "short series returns no_warmup" do
      {:no_warmup, 0} = Sim.Warmup.detect([1.0, 2.0, 3.0])
    end
  end

  # ============================================================
  # TIME-WINDOW STATISTICS
  # ============================================================

  describe "Sim.TimeSeries" do
    test "counts arrivals and departures per window" do
      ts =
        Sim.TimeSeries.new(window_size: 100.0)
        |> Sim.TimeSeries.record(:arrive, 10.0)
        |> Sim.TimeSeries.record(:arrive, 50.0)
        |> Sim.TimeSeries.record(:arrive, 150.0)
        |> Sim.TimeSeries.record(:depart, 80.0)
        |> Sim.TimeSeries.record(:depart, 180.0)

      windows = Sim.TimeSeries.summarize(ts)

      assert length(windows) == 2
      w0 = Enum.at(windows, 0)
      w1 = Enum.at(windows, 1)

      assert w0.arrivals == 2
      assert w0.departures == 1
      assert w1.arrivals == 1
      assert w1.departures == 1
    end

    test "computes utilization from busy spans" do
      ts =
        Sim.TimeSeries.new(window_size: 100.0)
        # 50% of window 0
        |> Sim.TimeSeries.record(:busy, 0.0, 50.0)
        # 90% of window 1
        |> Sim.TimeSeries.record(:busy, 100.0, 190.0)

      windows = Sim.TimeSeries.summarize(ts)

      assert length(windows) == 2
      assert Enum.at(windows, 0).utilization == 0.5
      assert Enum.at(windows, 1).utilization == 0.9
    end

    test "busy span clipped to window boundaries" do
      # Span crosses window boundary
      ts =
        Sim.TimeSeries.new(window_size: 100.0)
        # 20 in w0, 30 in w1
        |> Sim.TimeSeries.record(:busy, 80.0, 130.0)

      windows = Sim.TimeSeries.summarize(ts)

      assert Enum.at(windows, 0).utilization == 0.2
      assert Enum.at(windows, 1).utilization == 0.3
    end

    test "from_events convenience" do
      events = [{:arrive, 10.0}, {:arrive, 50.0}, {:depart, 80.0}]
      ts = Sim.TimeSeries.from_events(events, window_size: 100.0)
      windows = Sim.TimeSeries.summarize(ts)

      assert length(windows) == 1
      assert hd(windows).arrivals == 2
    end
  end

  # ============================================================
  # ENTITY ATTRIBUTES
  # ============================================================

  defmodule PriorityLine do
    use Sim.DSL

    model :priority_line do
      resource(:machine, capacity: 1)

      process :part do
        arrive(every: exponential(5.0))
        assign(:priority, :normal)
        seize(:machine)
        hold(exponential(3.0))
        release(:machine)
        depart
      end
    end
  end

  describe "entity attributes (assign)" do
    test "assign verb compiles and runs" do
      {:ok, result} = PriorityLine.run(stop_time: 5_000.0, seed: 42)

      assert result.stats[:part].completed > 0
      assert result.stats[:machine].grants > 0
    end

    test "assign is deterministic" do
      {:ok, r1} = PriorityLine.run(stop_time: 2_000.0, seed: 42)
      {:ok, r2} = PriorityLine.run(stop_time: 2_000.0, seed: 42)

      assert r1.stats[:part].completed == r2.stats[:part].completed
    end
  end

  # ============================================================
  # VALIDATION FRAMEWORK
  # ============================================================

  describe "Sim.Validate" do
    test "matching data gives :valid verdict" do
      # Same generator, deterministic
      :rand.seed(:exsss, {42, 42, 42})
      historical = Enum.map(1..50, fn _ -> 100.0 + :rand.uniform() * 10 - 5 end)
      :rand.seed(:exsss, {43, 43, 43})
      simulated = Enum.map(1..50, fn _ -> 100.5 + :rand.uniform() * 10 - 5 end)

      report = Sim.Validate.compare(historical, simulated, tolerance: 15.0)

      assert report.verdict in [:valid, :marginal]
      assert report.mean_pct_error < 15.0
    end

    test "mismatched data gives :invalid verdict" do
      historical = Enum.map(1..50, fn _ -> 100.0 + :rand.uniform() * 5 end)
      simulated = Enum.map(1..50, fn _ -> 200.0 + :rand.uniform() * 5 end)

      report = Sim.Validate.compare(historical, simulated)

      assert report.verdict == :invalid
      assert report.mean_pct_error > 50.0
    end

    test "identical data gives perfect validation" do
      data = Enum.map(1..30, fn i -> i * 3.0 end)

      report = Sim.Validate.compare(data, data)

      assert report.mean_error == 0.0
      assert report.mean_abs_error == 0.0
      assert report.ks_statistic == 0.0
      assert report.verdict == :valid
    end

    test "report prints without error" do
      historical = [100.0, 105.0, 98.0, 103.0, 110.0]
      simulated = [100.5, 105.2, 98.1, 103.3, 109.8]

      report = Sim.Validate.report(historical, simulated)

      assert report.verdict in [:valid, :marginal]
      assert report.n_paired == 5
    end

    test "KS statistic detects distributional difference" do
      # Uniform vs heavily skewed
      uniform = Enum.map(1..100, fn i -> i * 1.0 end)
      skewed = Enum.map(1..100, fn _ -> :math.exp(:rand.uniform() * 3) end)

      report = Sim.Validate.compare(uniform, skewed)

      assert report.ks_statistic > 0.3
    end
  end
end
