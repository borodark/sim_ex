defmodule SimTest do
  use ExUnit.Case

  describe "M/M/1 queue (Law Chapter 1)" do
    @tag timeout: 30_000
    test "utilization converges to rho = lambda/mu" do
      # lambda = 1.0 (interarrival), mu = 2.0 (service rate = 1/0.5)
      # rho = 1.0 / 2.0 = 0.5
      {:ok, result} =
        Sim.run(
          entities: [
            {:arrivals, Sim.Source,
             %{id: :arrivals, target: :server, interarrival: {:exponential, 1.0}, seed: 42}},
            {:server, Sim.Resource,
             %{id: :server, capacity: 1, service: {:exponential, 0.5}, seed: 99}}
          ],
          initial_events: [{0.0, :arrivals, :generate}],
          stop_time: 50_000.0
        )

      assert result.events > 0
      assert result.clock <= 50_000.0

      server_stats = result.stats[:server]
      assert server_stats.arrivals > 40_000
      assert server_stats.departures > 40_000

      # Mean wait should be positive (rho = 0.5 → E[W] = rho/(mu-lambda) = 0.5)
      assert server_stats.mean_wait > 0.0
      assert server_stats.mean_wait < 2.0
    end

    test "M/M/1 with high utilization" do
      # lambda = 1.0, mu = 1.25 (service mean = 0.8), rho = 0.8
      {:ok, result} =
        Sim.run(
          entities: [
            {:arrivals, Sim.Source,
             %{id: :arrivals, target: :server, interarrival: {:exponential, 1.0}, seed: 7}},
            {:server, Sim.Resource,
             %{id: :server, capacity: 1, service: {:exponential, 0.8}, seed: 13}}
          ],
          initial_events: [{0.0, :arrivals, :generate}],
          stop_time: 10_000.0
        )

      server_stats = result.stats[:server]
      # Higher utilization → longer waits
      assert server_stats.mean_wait > 1.0
    end
  end

  describe "M/M/c queue" do
    test "two servers reduce waiting" do
      # Same arrivals, but capacity = 2
      {:ok, r1} =
        Sim.run(
          entities: [
            {:arrivals, Sim.Source,
             %{id: :arrivals, target: :server, interarrival: {:exponential, 1.0}, seed: 42}},
            {:server, Sim.Resource,
             %{id: :server, capacity: 1, service: {:exponential, 0.5}, seed: 99}}
          ],
          initial_events: [{0.0, :arrivals, :generate}],
          stop_time: 10_000.0
        )

      {:ok, r2} =
        Sim.run(
          entities: [
            {:arrivals, Sim.Source,
             %{id: :arrivals, target: :server, interarrival: {:exponential, 1.0}, seed: 42}},
            {:server, Sim.Resource,
             %{id: :server, capacity: 2, service: {:exponential, 0.5}, seed: 99}}
          ],
          initial_events: [{0.0, :arrivals, :generate}],
          stop_time: 10_000.0
        )

      # Two servers should have lower mean wait
      assert r2.stats[:server].mean_wait < r1.stats[:server].mean_wait
    end
  end

  describe "deterministic" do
    test "same seed produces same results" do
      run = fn ->
        Sim.run(
          entities: [
            {:arrivals, Sim.Source,
             %{id: :arrivals, target: :server, interarrival: {:exponential, 1.0}, seed: 42}},
            {:server, Sim.Resource,
             %{id: :server, capacity: 1, service: {:exponential, 0.5}, seed: 99}}
          ],
          initial_events: [{0.0, :arrivals, :generate}],
          stop_time: 1_000.0
        )
      end

      {:ok, r1} = run.()
      {:ok, r2} = run.()

      assert r1.events == r2.events
      assert r1.stats[:server].arrivals == r2.stats[:server].arrivals
      assert r1.stats[:server].mean_wait == r2.stats[:server].mean_wait
    end
  end

  describe "PHOLD benchmark" do
    test "runs to completion" do
      result =
        Sim.PHOLD.run(
          num_lps: 100,
          events_per_lp: 4,
          remote_fraction: 0.25,
          stop_time: 10.0
        )

      assert result.total_events > 400
      assert result.events_per_second > 0
      assert result.wall_time_ms >= 0
    end

    test "remote_fraction=0 keeps all events local" do
      result =
        Sim.PHOLD.run(
          num_lps: 10,
          events_per_lp: 4,
          remote_fraction: 0.0,
          stop_time: 10.0
        )

      # Should still complete
      assert result.total_events > 40
    end
  end

  describe "Calendar" do
    test "FIFO ordering within same timestamp" do
      {:ok, cal} = Sim.Calendar.start_link(name: nil)

      Sim.Calendar.push(cal, 1.0, :a, :first)
      Sim.Calendar.push(cal, 1.0, :b, :second)
      Sim.Calendar.push(cal, 1.0, :c, :third)

      {:ok, {1.0, :a, :first}} = Sim.Calendar.pop(cal)
      {:ok, {1.0, :b, :second}} = Sim.Calendar.pop(cal)
      {:ok, {1.0, :c, :third}} = Sim.Calendar.pop(cal)
      :empty = Sim.Calendar.pop(cal)

      GenServer.stop(cal)
    end

    test "time ordering" do
      {:ok, cal} = Sim.Calendar.start_link(name: nil)

      Sim.Calendar.push(cal, 3.0, :c, :late)
      Sim.Calendar.push(cal, 1.0, :a, :early)
      Sim.Calendar.push(cal, 2.0, :b, :middle)

      {:ok, {1.0, :a, :early}} = Sim.Calendar.pop(cal)
      {:ok, {2.0, :b, :middle}} = Sim.Calendar.pop(cal)
      {:ok, {3.0, :c, :late}} = Sim.Calendar.pop(cal)

      GenServer.stop(cal)
    end
  end

  describe "Statistics" do
    test "Welford mean and variance" do
      {:ok, stats} = Sim.Statistics.start_link(name: nil)

      for v <- [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0] do
        Sim.Statistics.record(stats, :test, v)
      end

      result = Sim.Statistics.get(stats, :test)
      assert result.n == 8
      assert_in_delta result.mean, 5.0, 0.01
      # Sample variance (n-1 denominator): 32/7 = 4.571...
      assert_in_delta result.variance, 4.571, 0.01

      GenServer.stop(stats)
    end
  end

  describe "Experiment" do
    test "replicate produces n results" do
      results = Sim.Experiment.replicate(fn seed -> %{value: seed * 2} end, 10)
      assert length(results) == 10
      assert hd(results).value == 2
    end

    test "compare detects significant difference" do
      result =
        Sim.Experiment.compare(
          config_a: fn seed -> %{metric: 10.0 + :rand.uniform() * seed / 100} end,
          config_b: fn seed -> %{metric: 20.0 + :rand.uniform() * seed / 100} end,
          seeds: 1..30,
          metric: :metric
        )

      assert result.significant == true
      # a < b
      assert result.mean_diff < 0
    end
  end
end
