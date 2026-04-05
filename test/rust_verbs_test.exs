defmodule Sim.RustVerbsTest do
  use ExUnit.Case

  @moduledoc """
  Tests for all DSL verbs in the Rust NIF engine.
  Each test builds a model as raw opts and runs via Sim.Engine.Rust.run/1.
  """

  # ============================================================
  # BASELINE — verify existing verbs still work
  # ============================================================

  describe "baseline (seize/hold/release/depart)" do
    test "barbershop completes jobs" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 16.0}},
                {:release, 0},
                {:depart, []}
              ],
              arrival_mean: 18.0
            }
          ],
          stop_tick: 100_000,
          seed: 42,
          batch_size: 1
        )

      stats = result.stats
      assert stats[:process_0].completed > 0
      assert stats[:process_0].mean_hold > 0.0
      assert stats[:resource_0].grants > 0
      assert stats[:resource_0].releases > 0
    end

    test "deterministic with same seed" do
      opts = [
        resources: [%{capacity: 1}],
        processes: [
          %{
            steps: [
              {:seize, 0},
              {:hold, {:exponential, 16.0}},
              {:release, 0},
              {:depart, []}
            ],
            arrival_mean: 18.0
          }
        ],
        stop_tick: 50_000,
        seed: 42,
        batch_size: 1
      ]

      {:ok, r1} = Sim.Engine.Rust.run(opts)
      {:ok, r2} = Sim.Engine.Rust.run(opts)

      assert r1.stats[:process_0].completed == r2.stats[:process_0].completed
      assert r1.events == r2.events
    end
  end

  # ============================================================
  # LABEL + ASSIGN — no-op verbs
  # ============================================================

  describe "label and assign (no-ops)" do
    test "label and assign don't break the flow" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}],
          processes: [
            %{
              steps: [
                {:assign, {:type, :widget}},
                {:seize, 0},
                {:hold, {:exponential, 5.0}},
                {:release, 0},
                {:label, :done},
                {:depart, []}
              ],
              arrival_mean: 8.0
            }
          ],
          stop_tick: 50_000,
          seed: 42,
          batch_size: 1
        )

      assert result.stats[:process_0].completed > 0
      assert result.stats[:resource_0].grants > 0
    end
  end

  # ============================================================
  # DECIDE — binary probabilistic branch
  # ============================================================

  describe "decide (binary branch)" do
    test "rework model: ~15% rework rate" do
      # Flow: seize machine -> hold -> release -> decide 0.15 :rework ->
      #       depart (good) | label(:rework) -> seize rework -> hold -> release -> depart
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 4.0}},
                {:release, 0},
                {:decide, {0.15, :rework_station}},
                {:depart, []},
                {:label, :rework_station},
                {:seize, 1},
                {:hold, {:exponential, 6.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 5.0
            }
          ],
          stop_tick: 200_000,
          seed: 42,
          batch_size: 1
        )

      machine_grants = result.stats[:resource_0].grants
      rework_grants = result.stats[:resource_1].grants

      assert machine_grants > 0
      assert rework_grants > 0

      rework_pct = rework_grants / machine_grants * 100
      assert rework_pct > 10, "rework too low: #{Float.round(rework_pct, 1)}%"
      assert rework_pct < 25, "rework too high: #{Float.round(rework_pct, 1)}%"
    end

    test "decide 0.0 means nobody branches" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 4.0}},
                {:release, 0},
                {:decide, {0.0, :rework_station}},
                {:depart, []},
                {:label, :rework_station},
                {:seize, 1},
                {:hold, {:exponential, 6.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 5.0
            }
          ],
          stop_tick: 50_000,
          seed: 42,
          batch_size: 1
        )

      assert result.stats[:resource_1].grants == 0
    end

    test "decide 1.0 means everyone branches" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 4.0}},
                {:release, 0},
                {:decide, {1.0, :rework_station}},
                {:depart, []},
                {:label, :rework_station},
                {:seize, 1},
                {:hold, {:exponential, 6.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 5.0
            }
          ],
          stop_tick: 50_000,
          seed: 42,
          batch_size: 1
        )

      assert result.stats[:resource_1].grants > 0
      # Everyone should branch, so rework grants == machine grants (within 1)
      assert abs(result.stats[:resource_1].grants - result.stats[:process_0].completed) <= 1
    end
  end

  # ============================================================
  # DECIDE_MULTI — weighted multi-way routing
  # ============================================================

  describe "decide_multi (multi-way routing)" do
    test "traffic splits roughly according to probabilities" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 3}, %{capacity: 2}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:decide_multi, [{0.5, :fast_lane}, {0.3, :medium_lane}, {0.2, :slow_lane}]},
                {:depart, []},
                {:label, :fast_lane},
                {:seize, 0},
                {:hold, {:exponential, 2.0}},
                {:release, 0},
                {:depart, []},
                {:label, :medium_lane},
                {:seize, 1},
                {:hold, {:exponential, 5.0}},
                {:release, 1},
                {:depart, []},
                {:label, :slow_lane},
                {:seize, 2},
                {:hold, {:exponential, 10.0}},
                {:release, 2},
                {:depart, []}
              ],
              arrival_mean: 3.0
            }
          ],
          stop_tick: 200_000,
          seed: 42,
          batch_size: 1
        )

      fast = result.stats[:resource_0].grants
      medium = result.stats[:resource_1].grants
      slow = result.stats[:resource_2].grants
      total = fast + medium + slow

      assert total > 0

      fast_pct = fast / total * 100
      medium_pct = medium / total * 100
      slow_pct = slow / total * 100

      assert fast_pct > 35, "fast too low: #{Float.round(fast_pct, 1)}%"
      assert fast_pct < 65, "fast too high: #{Float.round(fast_pct, 1)}%"
      assert medium_pct > 15, "medium too low: #{Float.round(medium_pct, 1)}%"
      assert medium_pct < 45, "medium too high: #{Float.round(medium_pct, 1)}%"
      assert slow_pct > 5, "slow too low: #{Float.round(slow_pct, 1)}%"
      assert slow_pct < 35, "slow too high: #{Float.round(slow_pct, 1)}%"
    end
  end

  # ============================================================
  # ROUTE — travel delay (hold without resource)
  # ============================================================

  describe "route (travel delay)" do
    test "route adds delay between stations" do
      # With route
      {:ok, r_route} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}, %{capacity: 2}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 3.0}},
                {:release, 0},
                {:route, {:exponential, 5.0}},
                {:seize, 1},
                {:hold, {:exponential, 4.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 10.0
            }
          ],
          stop_tick: 100_000,
          seed: 42,
          batch_size: 1
        )

      # Without route
      {:ok, r_direct} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}, %{capacity: 2}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 3.0}},
                {:release, 0},
                {:seize, 1},
                {:hold, {:exponential, 4.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 10.0
            }
          ],
          stop_tick: 100_000,
          seed: 42,
          batch_size: 1
        )

      # Route version should have higher mean hold (includes route delay)
      assert r_route.stats[:process_0].mean_hold > r_direct.stats[:process_0].mean_hold
      assert r_route.stats[:process_0].completed > 0
      assert r_direct.stats[:process_0].completed > 0
    end

    test "route with constant delay" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 3.0}},
                {:release, 0},
                {:route, {:constant, 5.0}},
                {:depart, []}
              ],
              arrival_mean: 10.0
            }
          ],
          stop_tick: 50_000,
          seed: 42,
          batch_size: 1
        )

      assert result.stats[:process_0].completed > 0
      # Mean hold should include route delay (~5 ticks)
      assert result.stats[:process_0].mean_hold > 3.0
    end
  end

  # ============================================================
  # BATCH — accumulate N parts
  # ============================================================

  describe "batch (accumulate N)" do
    test "parts batch in groups of 5" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 2.0}},
                {:release, 0},
                {:batch, 5},
                {:seize, 1},
                {:hold, {:exponential, 4.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 3.0
            }
          ],
          stop_tick: 100_000,
          seed: 42,
          batch_size: 1
        )

      machine = result.stats[:resource_0].grants
      box = result.stats[:resource_1].grants
      completed = result.stats[:process_0].completed

      assert machine > 0
      assert box > 0
      assert completed > 0

      # Box grants should equal completed (each batched part goes through)
      assert abs(box - completed) <= 1
    end

    test "batch 1 is a no-op" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 2}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 3.0}},
                {:release, 0},
                {:batch, 1},
                {:depart, []}
              ],
              arrival_mean: 5.0
            }
          ],
          stop_tick: 50_000,
          seed: 42,
          batch_size: 1
        )

      assert result.stats[:process_0].completed > 0
      # completed <= grants (some jobs may be in-flight at stop_tick)
      assert result.stats[:resource_0].grants >= result.stats[:process_0].completed
    end
  end

  # ============================================================
  # SPLIT — one becomes N
  # ============================================================

  describe "split (one becomes N)" do
    test "split 3 triples downstream traffic" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 1}, %{capacity: 3}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 5.0}},
                {:release, 0},
                {:split, 3},
                {:seize, 1},
                {:hold, {:exponential, 3.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 10.0
            }
          ],
          stop_tick: 100_000,
          seed: 42,
          batch_size: 1
        )

      cutter = result.stats[:resource_0].grants
      finisher = result.stats[:resource_1].grants

      assert cutter > 0
      assert finisher > 0

      ratio = finisher / cutter
      assert ratio > 2.5, "expected ~3x, got #{Float.round(ratio, 1)}x"
      assert ratio < 3.5, "expected ~3x, got #{Float.round(ratio, 1)}x"
    end
  end

  # ============================================================
  # COMBINE — N become 1
  # ============================================================

  describe "combine (N become 1)" do
    test "combine 4 reduces downstream by ~4x" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 3}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 2.0}},
                {:release, 0},
                {:combine, 4},
                {:seize, 1},
                {:hold, {:exponential, 5.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 3.0
            }
          ],
          stop_tick: 200_000,
          seed: 42,
          batch_size: 1
        )

      prep = result.stats[:resource_0].grants
      assembler = result.stats[:resource_1].grants

      assert prep > 0
      assert assembler > 0

      ratio = prep / max(assembler, 1)
      assert ratio > 3.0, "expected ~4x reduction, got #{Float.round(ratio, 1)}x"
      assert ratio < 5.5, "expected ~4x reduction, got #{Float.round(ratio, 1)}x"
    end
  end

  # ============================================================
  # SPLIT + COMBINE pipeline (conservation)
  # ============================================================

  describe "split + combine (conservation)" do
    test "split 4 then combine 4: upstream = downstream" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 1}, %{capacity: 4}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 3.0}},
                {:release, 0},
                {:split, 4},
                {:seize, 1},
                {:hold, {:exponential, 4.0}},
                {:release, 1},
                {:combine, 4},
                {:seize, 2},
                {:hold, {:exponential, 5.0}},
                {:release, 2},
                {:depart, []}
              ],
              arrival_mean: 15.0
            }
          ],
          stop_tick: 200_000,
          seed: 42,
          batch_size: 1
        )

      cutter = result.stats[:resource_0].grants
      processor = result.stats[:resource_1].grants
      assembler = result.stats[:resource_2].grants

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

  # ============================================================
  # COMBINED — decide + batch (quality line)
  # ============================================================

  describe "combined (decide + batch)" do
    test "quality line: rework + batching" do
      {:ok, result} =
        Sim.Engine.Rust.run(
          resources: [%{capacity: 3}, %{capacity: 1}, %{capacity: 1}],
          processes: [
            %{
              steps: [
                {:seize, 0},
                {:hold, {:exponential, 3.0}},
                {:release, 0},
                {:decide, {0.15, :rework_loop}},
                {:batch, 4},
                {:seize, 2},
                {:hold, {:exponential, 2.0}},
                {:release, 2},
                {:depart, []},
                {:label, :rework_loop},
                {:seize, 1},
                {:hold, {:exponential, 8.0}},
                {:release, 1},
                {:depart, []}
              ],
              arrival_mean: 4.0
            }
          ],
          stop_tick: 200_000,
          seed: 42,
          batch_size: 1
        )

      machine = result.stats[:resource_0].grants
      rework = result.stats[:resource_1].grants
      packer = result.stats[:resource_2].grants
      completed = result.stats[:process_0].completed

      assert machine > 0
      assert rework > 0
      assert packer > 0
      assert completed > 0

      rework_pct = rework / machine * 100
      assert rework_pct > 5
      assert rework_pct < 30
    end
  end

  # ============================================================
  # DETERMINISM — all new verbs
  # ============================================================

  describe "determinism" do
    test "decide model is deterministic" do
      opts = [
        resources: [%{capacity: 2}, %{capacity: 1}],
        processes: [
          %{
            steps: [
              {:seize, 0},
              {:hold, {:exponential, 4.0}},
              {:release, 0},
              {:decide, {0.2, :rework}},
              {:depart, []},
              {:label, :rework},
              {:seize, 1},
              {:hold, {:exponential, 6.0}},
              {:release, 1},
              {:depart, []}
            ],
            arrival_mean: 5.0
          }
        ],
        stop_tick: 50_000,
        seed: 99,
        batch_size: 1
      ]

      {:ok, r1} = Sim.Engine.Rust.run(opts)
      {:ok, r2} = Sim.Engine.Rust.run(opts)

      assert r1.stats[:resource_1].grants == r2.stats[:resource_1].grants
      assert r1.stats[:process_0].completed == r2.stats[:process_0].completed
      assert r1.events == r2.events
    end

    test "batch model is deterministic" do
      opts = [
        resources: [%{capacity: 2}, %{capacity: 1}],
        processes: [
          %{
            steps: [
              {:seize, 0},
              {:hold, {:exponential, 2.0}},
              {:release, 0},
              {:batch, 5},
              {:seize, 1},
              {:hold, {:exponential, 4.0}},
              {:release, 1},
              {:depart, []}
            ],
            arrival_mean: 3.0
          }
        ],
        stop_tick: 50_000,
        seed: 42,
        batch_size: 1
      ]

      {:ok, r1} = Sim.Engine.Rust.run(opts)
      {:ok, r2} = Sim.Engine.Rust.run(opts)

      assert r1.stats[:process_0].completed == r2.stats[:process_0].completed
      assert r1.events == r2.events
    end

    test "split/combine model is deterministic" do
      opts = [
        resources: [%{capacity: 1}, %{capacity: 4}, %{capacity: 1}],
        processes: [
          %{
            steps: [
              {:seize, 0},
              {:hold, {:exponential, 3.0}},
              {:release, 0},
              {:split, 4},
              {:seize, 1},
              {:hold, {:exponential, 4.0}},
              {:release, 1},
              {:combine, 4},
              {:seize, 2},
              {:hold, {:exponential, 5.0}},
              {:release, 2},
              {:depart, []}
            ],
            arrival_mean: 15.0
          }
        ],
        stop_tick: 50_000,
        seed: 42,
        batch_size: 1
      ]

      {:ok, r1} = Sim.Engine.Rust.run(opts)
      {:ok, r2} = Sim.Engine.Rust.run(opts)

      assert r1.stats[:process_0].completed == r2.stats[:process_0].completed
      assert r1.stats[:resource_1].grants == r2.stats[:resource_1].grants
      assert r1.events == r2.events
    end
  end
end
