%% sim_diasca_probe.erl
%%
%% Pure functions extracted from Sim-Diasca's class_TimeManager.erl
%% (Olivier Boudeville, EDF R&D, LGPL-3.0) for property-based testing.
%%
%% These functions implement the spontaneous scheduling agenda and
%% logical timestamp comparison — the core of Sim-Diasca's tick-diasca
%% synchronization model. They are pure (no WOOPER state, no processes,
%% no side effects) and can be tested with PropEr in isolation.
%%
%% Source: github.com/Olivier-Boudeville-EDF/Sim-Diasca
%%   class_TimeManager.erl lines 7753-7810 (schedule_as_spontaneous_for)
%%   class_TimeManager.erl lines 5999-6033 (min/max_timestamp)
%%
%% The original code uses set_utils from the Myriad library. We replace
%% it with ordsets for self-containment.

-module(sim_diasca_probe).

-export([schedule_as_spontaneous_for/3,
         min_timestamp/2,
         max_timestamp/2]).

%% --- Spontaneous scheduling agenda ---
%%
%% An agenda is a sorted list of {TickOffset, ActorSet} pairs.
%% schedule_as_spontaneous_for/3 inserts an actor into the agenda at
%% the given tick, maintaining sort order and merging into existing
%% tick entries.

schedule_as_spontaneous_for(TickOffset, Actor, Agenda) ->
    insert_as_spontaneous_for(TickOffset, Actor, Agenda, _Reversed=[]).

%% End of list — insert at last position:
insert_as_spontaneous_for(Tick, Actor, _BeginList=[], Reversed) ->
    lists:reverse([{Tick, ordsets:from_list([Actor])} | Reversed]);

%% Tick already has an entry — add actor to the set:
insert_as_spontaneous_for(Tick, Actor,
        [{Tick, ActorSet} | Rest], Reversed) ->
    NewActorSet = ordsets:add_element(Actor, ActorSet),
    lists:reverse([{Tick, NewActorSet} | Reversed]) ++ Rest;

%% Went past the correct tick (CurrentTick > Tick) — insert here:
insert_as_spontaneous_for(Tick, Actor,
        BeginList=[{CurrentTick, _} | _], Reversed)
        when CurrentTick > Tick ->
    lists:reverse([{Tick, ordsets:from_list([Actor])} | Reversed])
        ++ BeginList;

%% CurrentTick < Tick — keep scanning:
insert_as_spontaneous_for(Tick, Actor, [Entry | BeginList], Reversed) ->
    insert_as_spontaneous_for(Tick, Actor, BeginList, [Entry | Reversed]).


%% --- Logical timestamp comparison ---
%%
%% A logical timestamp is {Tick, Diasca} where both are non-negative
%% integers, or the atom 'undefined'.

min_timestamp(undefined, Second) -> Second;
min_timestamp(First, undefined) -> First;
min_timestamp(First={F1, _}, _Second={S1, _}) when F1 < S1 -> First;
min_timestamp(First={F1, F2}, _Second={F1, S2}) when F2 < S2 -> First;
min_timestamp(_First, Second) -> Second.

max_timestamp(undefined, Second) -> Second;
max_timestamp(First, undefined) -> First;
max_timestamp(_First={F1, _}, Second={S1, _}) when F1 < S1 -> Second;
max_timestamp(_First={F1, F2}, Second={F1, S2}) when F2 < S2 -> Second;
max_timestamp(First, _Second) -> First.
