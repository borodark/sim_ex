# Minimal PropEr probe against Sim-Diasca's pure scheduling functions.
#
# We extracted two pure functions from class_TimeManager.erl
# (Olivier Boudeville, EDF R&D, LGPL-3.0) and translated them to
# Elixir for testing with PropCheck. The functions implement:
#
#   1. The spontaneous scheduling agenda — a sorted list of
#      {tick, actor_set} pairs maintained by insert_as_spontaneous_for/4.
#      This is the core calendar insertion logic of Sim-Diasca's
#      tick-diasca synchronization model.
#
#   2. Logical timestamp comparison — min_timestamp/2 and max_timestamp/2
#      over {tick, diasca} pairs, used to determine scheduling order.
#
# Source: github.com/Olivier-Boudeville-EDF/Sim-Diasca
#   class_TimeManager.erl lines 7753-7810, 5999-6033
#
# These functions are pure (no WOOPER state, no processes). The
# extraction itself validates that they have no hidden state dependencies.

defmodule SimDiasca.Probe do
  @moduledoc """
  Pure functions extracted from Sim-Diasca's class_TimeManager.erl,
  translated to Elixir for property-based testing.
  """

  # --- Spontaneous scheduling agenda ---

  def schedule_as_spontaneous_for(tick, actor, agenda) do
    insert_as_spontaneous_for(tick, actor, agenda, _reversed = [])
  end

  # End of list — insert at last position
  defp insert_as_spontaneous_for(tick, actor, [], reversed) do
    Enum.reverse([{tick, MapSet.new([actor])} | reversed])
  end

  # Tick already has an entry — add actor to the set
  defp insert_as_spontaneous_for(tick, actor, [{tick, actor_set} | rest], reversed) do
    new_set = MapSet.put(actor_set, actor)
    Enum.reverse([{tick, new_set} | reversed]) ++ rest
  end

  # Went past the correct tick — insert here
  defp insert_as_spontaneous_for(tick, actor, [{current_tick, _} | _] = begin_list, reversed)
       when current_tick > tick do
    Enum.reverse([{tick, MapSet.new([actor])} | reversed]) ++ begin_list
  end

  # Current tick < target tick — keep scanning
  defp insert_as_spontaneous_for(tick, actor, [entry | begin_list], reversed) do
    insert_as_spontaneous_for(tick, actor, begin_list, [entry | reversed])
  end

  # --- Logical timestamp comparison ---

  def min_timestamp(nil, second), do: second
  def min_timestamp(first, nil), do: first
  def min_timestamp({f1, _} = first, {s1, _}) when f1 < s1, do: first
  def min_timestamp({f1, f2} = first, {f1, s2}) when f2 < s2, do: first
  def min_timestamp(_first, second), do: second

  def max_timestamp(nil, second), do: second
  def max_timestamp(first, nil), do: first
  def max_timestamp({f1, _}, {s1, _} = second) when f1 < s1, do: second
  def max_timestamp({f1, f2}, {f1, s2} = second) when f2 < s2, do: second
  def max_timestamp(first, _second), do: first
end

defmodule SimDiasca.ProbeTest do
  use ExUnit.Case
  use PropCheck

  @moduletag timeout: 120_000

  # ================================================================
  # Properties: schedule_as_spontaneous_for
  # ================================================================

  property "agenda is always sorted by tick after any insertion sequence", numtests: 200 do
    forall insertions <- list({non_neg_integer(), oneof([:a, :b, :c, :d, :e, :f, :g, :h])}) do
      agenda =
        Enum.reduce(insertions, [], fn {tick, actor}, acc ->
          SimDiasca.Probe.schedule_as_spontaneous_for(tick, actor, acc)
        end)

      ticks = Enum.map(agenda, fn {t, _} -> t end)
      ticks == Enum.sort(ticks)
    end
  end

  property "agenda has no duplicate tick entries", numtests: 200 do
    forall insertions <- list({non_neg_integer(), oneof([:a, :b, :c, :d, :e, :f, :g, :h])}) do
      agenda =
        Enum.reduce(insertions, [], fn {tick, actor}, acc ->
          SimDiasca.Probe.schedule_as_spontaneous_for(tick, actor, acc)
        end)

      ticks = Enum.map(agenda, fn {t, _} -> t end)
      ticks == Enum.uniq(ticks)
    end
  end

  property "every inserted actor appears at its tick", numtests: 200 do
    forall insertions <- list({non_neg_integer(), oneof([:a, :b, :c, :d, :e, :f, :g, :h])}) do
      agenda =
        Enum.reduce(insertions, [], fn {tick, actor}, acc ->
          SimDiasca.Probe.schedule_as_spontaneous_for(tick, actor, acc)
        end)

      Enum.all?(insertions, fn {tick, actor} ->
        case List.keyfind(agenda, tick, 0) do
          {^tick, actor_set} -> MapSet.member?(actor_set, actor)
          nil -> false
        end
      end)
    end
  end

  property "scheduling same actor at same tick is idempotent", numtests: 200 do
    forall {tick, actor} <- {non_neg_integer(), oneof([:a, :b, :c])} do
      a1 = SimDiasca.Probe.schedule_as_spontaneous_for(tick, actor, [])
      a2 = SimDiasca.Probe.schedule_as_spontaneous_for(tick, actor, a1)
      a1 == a2
    end
  end

  # ================================================================
  # Properties: min_timestamp / max_timestamp
  # ================================================================

  property "min_timestamp returns value <= both inputs", numtests: 200 do
    forall {a, b} <-
             {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} do
      min = SimDiasca.Probe.min_timestamp(a, b)
      min <= a and min <= b
    end
  end

  property "max_timestamp returns value >= both inputs", numtests: 200 do
    forall {a, b} <-
             {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} do
      max = SimDiasca.Probe.max_timestamp(a, b)
      max >= a and max >= b
    end
  end

  property "min <= max for any pair of timestamps", numtests: 200 do
    forall {a, b} <-
             {{non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}} do
      min = SimDiasca.Probe.min_timestamp(a, b)
      max = SimDiasca.Probe.max_timestamp(a, b)
      min <= max
    end
  end

  property "min/max_timestamp handle nil correctly", numtests: 100 do
    forall t <- {non_neg_integer(), non_neg_integer()} do
      SimDiasca.Probe.min_timestamp(nil, t) == t and
        SimDiasca.Probe.min_timestamp(t, nil) == t and
        SimDiasca.Probe.min_timestamp(nil, nil) == nil and
        SimDiasca.Probe.max_timestamp(nil, t) == t and
        SimDiasca.Probe.max_timestamp(t, nil) == t and
        SimDiasca.Probe.max_timestamp(nil, nil) == nil
    end
  end
end
