%% sim_diasca_probe_proper.erl
%%
%% PropEr properties for Sim-Diasca's pure scheduling functions.
%%
%% This is the "minimal probe" described in the Erlang 2026 paper:
%% we extracted the pure core of class_TimeManager.erl and subjected
%% it to property-based testing with PropEr. The methodology is
%% general; the postconditions encode domain knowledge about what
%% a correct scheduling agenda and timestamp comparator must satisfy.
%%
%% Run:
%%   erlc -pa ../../deps/proper/ebin sim_diasca_probe.erl sim_diasca_probe_proper.erl
%%   erl -pa ../../deps/proper/ebin -noshell -eval \
%%     'sim_diasca_probe_proper:run_all(), halt().'

-module(sim_diasca_probe_proper).

-include("proper.hrl").

-export([run_all/0]).

%% ================================================================
%% Generators
%% ================================================================

%% Random tick offset (non-negative integer, bounded for tractability)
tick() -> non_neg_integer().

%% Random actor name (atom)
actor() -> oneof([a, b, c, d, e, f, g, h]).

%% Random logical timestamp {Tick, Diasca}
timestamp() -> {non_neg_integer(), non_neg_integer()}.

%% Random optional timestamp (may be undefined)
opt_timestamp() -> oneof([undefined, timestamp()]).

%% Random sequence of {Tick, Actor} insertions
insertion_sequence() ->
    list({tick(), actor()}).

%% ================================================================
%% Properties: schedule_as_spontaneous_for
%% ================================================================

%% PROPERTY 1: The agenda is always sorted by tick after any sequence
%% of insertions.
prop_agenda_sorted() ->
    ?FORALL(Insertions, insertion_sequence(),
        begin
            Agenda = lists:foldl(
                fun({Tick, Actor}, Acc) ->
                    sim_diasca_probe:schedule_as_spontaneous_for(Tick, Actor, Acc)
                end,
                [],
                Insertions),
            Ticks = [T || {T, _} <- Agenda],
            Ticks =:= lists:sort(Ticks)
        end).

%% PROPERTY 2: No duplicate tick entries — each tick appears at most
%% once in the agenda.
prop_agenda_no_duplicate_ticks() ->
    ?FORALL(Insertions, insertion_sequence(),
        begin
            Agenda = lists:foldl(
                fun({Tick, Actor}, Acc) ->
                    sim_diasca_probe:schedule_as_spontaneous_for(Tick, Actor, Acc)
                end,
                [],
                Insertions),
            Ticks = [T || {T, _} <- Agenda],
            Ticks =:= lists:usort(Ticks)
        end).

%% PROPERTY 3: Every inserted actor appears in the agenda at the
%% correct tick.
prop_agenda_contains_all() ->
    ?FORALL(Insertions, insertion_sequence(),
        begin
            Agenda = lists:foldl(
                fun({Tick, Actor}, Acc) ->
                    sim_diasca_probe:schedule_as_spontaneous_for(Tick, Actor, Acc)
                end,
                [],
                Insertions),
            lists:all(
                fun({Tick, Actor}) ->
                    case lists:keyfind(Tick, 1, Agenda) of
                        {Tick, ActorSet} ->
                            ordsets:is_element(Actor, ActorSet);
                        false ->
                            false
                    end
                end,
                Insertions)
        end).

%% PROPERTY 4: Idempotence — scheduling the same actor at the same
%% tick twice produces the same agenda as scheduling it once.
prop_agenda_idempotent() ->
    ?FORALL({Tick, Actor}, {tick(), actor()},
        begin
            A1 = sim_diasca_probe:schedule_as_spontaneous_for(Tick, Actor, []),
            A2 = sim_diasca_probe:schedule_as_spontaneous_for(Tick, Actor, A1),
            A1 =:= A2
        end).

%% ================================================================
%% Properties: min_timestamp / max_timestamp
%% ================================================================

%% PROPERTY 5: min_timestamp returns a value <= both inputs
%% (using lexicographic ordering on {Tick, Diasca}).
prop_min_timestamp_correct() ->
    ?FORALL({A, B}, {timestamp(), timestamp()},
        begin
            Min = sim_diasca_probe:min_timestamp(A, B),
            Min =< A andalso Min =< B
        end).

%% PROPERTY 6: max_timestamp returns a value >= both inputs.
prop_max_timestamp_correct() ->
    ?FORALL({A, B}, {timestamp(), timestamp()},
        begin
            Max = sim_diasca_probe:max_timestamp(A, B),
            Max >= A andalso Max >= B
        end).

%% PROPERTY 7: min and max are consistent — min <= max.
prop_min_max_consistent() ->
    ?FORALL({A, B}, {timestamp(), timestamp()},
        begin
            Min = sim_diasca_probe:min_timestamp(A, B),
            Max = sim_diasca_probe:max_timestamp(A, B),
            Min =< Max
        end).

%% PROPERTY 8: min_timestamp handles undefined correctly.
prop_min_timestamp_undefined() ->
    ?FORALL(T, timestamp(),
        begin
            sim_diasca_probe:min_timestamp(undefined, T) =:= T
            andalso sim_diasca_probe:min_timestamp(T, undefined) =:= T
            andalso sim_diasca_probe:min_timestamp(undefined, undefined) =:= undefined
        end).

%% ================================================================
%% Runner
%% ================================================================

run_all() ->
    Properties = [
        {"agenda_sorted",           fun prop_agenda_sorted/0},
        {"agenda_no_duplicate_ticks", fun prop_agenda_no_duplicate_ticks/0},
        {"agenda_contains_all",     fun prop_agenda_contains_all/0},
        {"agenda_idempotent",       fun prop_agenda_idempotent/0},
        {"min_timestamp_correct",   fun prop_min_timestamp_correct/0},
        {"max_timestamp_correct",   fun prop_max_timestamp_correct/0},
        {"min_max_consistent",      fun prop_min_max_consistent/0},
        {"min_timestamp_undefined", fun prop_min_timestamp_undefined/0}
    ],
    Results = lists:map(
        fun({Name, PropFun}) ->
            io:format("~n=== ~s ===~n", [Name]),
            case proper:quickcheck(PropFun(), [{numtests, 200}]) of
                true ->
                    io:format("  PASSED (200 tests)~n"),
                    {Name, pass};
                false ->
                    io:format("  *** FAILED ***~n"),
                    {Name, fail}
            end
        end,
        Properties),
    Passed = length([x || {_, pass} <- Results]),
    Failed = length([x || {_, fail} <- Results]),
    io:format("~n=== SUMMARY: ~p passed, ~p failed ===~n", [Passed, Failed]),
    case Failed of
        0 -> ok;
        _ -> {failures, [N || {N, fail} <- Results]}
    end.
