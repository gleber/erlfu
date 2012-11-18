-module(future).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([new/0, new/1,

         set/2, error/2, error/3, error/4,

         get/1, realize/1, ready/1,

         attach/1, handle/1, done/1]).

-export([collect/1]).

-record(future, {pid, ref, result}).

notify(Ref, Pid, Result) when is_pid(Pid) ->
    notify(Ref, [Pid], Result);
notify(_, [], _) ->
    ok;
notify(Ref, [P|T], Result) ->
    P ! {future, Ref, Result},
    notify(Ref, T, Result).

loop(Ref, Waiting, undefined) ->
    receive
        {ready, Ref, Requester} ->
            Requester ! {future_ready, Ref, false},
            loop(Ref, Waiting, undefined);
        {set, Ref, Result} ->
            notify(Ref, Waiting, Result),
            loop(Ref, [], Result);
        {get, Ref, Requester} ->
            loop(Ref, [Requester | Waiting], undefined)
    end;
loop(Ref, [], {_Type, _Value} = Result) ->
    receive
        {done, Ref} ->
            ok;
        {ready, Ref, Requester} ->
            Requester ! {future_ready, Ref, true},
            loop(Ref, [], Result);
        {get, Ref, Requester} ->
            notify(Ref, Requester, Result),
            loop(Ref, [], Result)
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
    Self#future{result = Val}.

set(Value, #future{pid = Pid, ref = Ref} = Self) ->
    Pid ! {set, Ref, {value, Value}},
    Self#future{result = {value, Value}}.

done(#future{pid = Pid, ref = Ref} = _Self) ->
    Pid ! {done, Ref},
    ok.

realize(#future{} = Self) ->
    Value = Self:get(),
    Self:done(),
    Self#future{pid = undefined, ref = undefined, result = {value, Value}}.

get(#future{result = undefined} = Self) ->
    Self:attach(),
    Self:handle();
get(#future{result = {value, Value}}) ->
    Value.

handle(#future{ref = Ref} = _Self) ->
    receive
        {future, Ref, {value, Value}} ->
            Value;
        {future, Ref, {error, {Class, Error, ErrorStacktrace}}} ->
            {'EXIT', {new_stacktrace, CurrentStacktrace}} = (catch error(new_stacktrace)),
            erlang:raise(Class, Error, ErrorStacktrace ++ CurrentStacktrace)
    end.

attach(#future{pid = Pid, ref = Ref, result = undefined} = _Self) ->
    link(Pid), %% should be monitor
    Pid ! {get, Ref, self()},
    Ref;
attach(#future{ref = Ref, result = {_Type, _Value} = Result} = _Self) ->
    self() ! {future, Ref, Result},
    Ref.

ready(#future{result = {_Type, _Value}}) ->
    true;
ready(#future{pid = Pid, ref = Ref, result = undefined} = _Self) ->
    Pid ! {ready, Ref, self()},
    receive
        {future_ready, Ref, Ready} ->
            Ready
    end.

collect(Futures) ->
    [ F:attach() || F <- Futures ],
    [ F:handle() || F <- Futures ].

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
