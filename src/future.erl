-module(future).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([new/0, new/1,

         set/2, error/2, error/3, error/4,

         attach/1, get/1, realize/1, done/1]).

-record(future, {pid, ref, value}).

notify(Ref, Pid, Value) when is_pid(Pid) ->
    notify(Ref, [Pid], Value);
notify(_, [], _) ->
    ok;
notify(Ref, [P|T], Value) ->
    P ! {future, Ref, Value},
    notify(Ref, T, Value).

loop(Ref, Waiting, undefined) ->
    receive
        {set, Ref, {Type, Value}} ->
            notify(Ref, Waiting, {Type, Value}),
            loop(Ref, [], {Type, Value});
        {get, Ref, Requester} ->
            loop(Ref, [Requester | Waiting], undefined)
    end;
loop(Ref, [], {Type, Value}) ->
    receive
        {done, Ref} ->
            ok;
        {get, Ref, Requester} ->
            notify(Ref, Requester, {Type, Value}),
            loop(Ref, [], {Type, Value})
    end.

new(Fun) ->
    Ref = make_ref(),
    Pid = spawn_link(fun() ->
                             Self = #future{pid = self(), ref = Ref},
                             spawn_link(fun() ->
                                                try
                                                    Res = Fun(),
                                                    Self:set(Res)
                                                catch
                                                    Class:Error ->
                                                        Self:error(Class, Error, erlang:get_stacktrace())
                                                end
                                        end),
                             loop(Ref, [], undefined)
                     end),
    #future{pid = Pid, ref = Ref}.

new() ->
    Ref = make_ref(),
    Pid = spawn_link(fun() ->
                             loop(Ref, [], undefined)
                     end),
    #future{pid = Pid, ref = Ref}.

error(Error, #future{} = Self) ->
    Self:error(error, Error).
error(Class, Error, #future{} = Self) ->
    Self:error(Class, Error, []).

error(Class, Error, Stacktrace, #future{pid = Pid, ref = Ref} = Self) ->
    Val = {error, {Class, Error, Stacktrace}},
    Pid ! {set, Ref, Val},
    Self#future{value = Val}.

set(Value, #future{pid = Pid, ref = Ref} = Self) ->
    Pid ! {set, Ref, {value, Value}},
    Self#future{value = {value, Value}}.

done(#future{pid = Pid, ref = Ref} = _Self) ->
    Pid ! {done, Ref},
    ok.

realize(#future{} = Self) ->
    Value = Self:get(),
    Self:done(),
    Self#future{pid = undefined, ref = undefined, value = {value, Value}}.

get(#future{ref = Ref, value = undefined} = Self) ->
    attach(Self),
    receive
        {future, Ref, {value, Value}} ->
            Value;
        {future, Ref, {error, {Class, Error, ErrorStacktrace}}} ->
            {'EXIT', {new_stacktrace, CurrentStacktrace}} = (catch error(new_stacktrace)),
            erlang:raise(Class, Error, ErrorStacktrace ++ CurrentStacktrace)
    end;
get(#future{value = {value, Value}}) ->
    Value.

attach(#future{pid = Pid, ref = Ref, value = undefined} = Self) ->
    link(Pid), %% should be monitor
    Pid ! {get, Ref, self()},
    Self;
attach(#future{ref = Ref, value = {value, Value}} = Self) ->
    self() ! {future, Ref, Value},
    Self.

%% =============================================================================
%%
%% Tests
%%
%% =============================================================================

-define(QC(Arg), proper:quickcheck(Arg, [])).

basic_test() ->
    true = ?QC(future:prop_basic()).

prop_basic() ->
    ?FORALL(X, term(),
            begin
                get_property(X),
                realize_property(X)
            end).

get_property(X) ->
    F = future:new(),
    F:set(X),
    Val = F:get(),
    F:done(),
    X == Val.

realize_property(X) ->
    F = future:new(),
    F:set(X),
    F2 = F:realize(),
    X == F2:get().
