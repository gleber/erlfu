-module(future).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([%% creating
         new/0, new/1,

         %% manipulating
         set/2, error/2, error/3, error/4, execute/2,

         %% getting
         get/1, realize/1, ready/1, call/1,
         attach/1, recv/1,

         %% finishing
         done/1, cancel/1]).

%% collections
-export([collect/1, map/1, chain/1, chain/2, wrap/1, wrap/2]).

%% wrappers
-export([timeout/1, timeout/2, safe/1]).

-define(is_future(F), is_record(F, future)).
-define(is_futurable(F), (?is_future(F) orelse is_function(F, 0))).

-record(future, {pid, ref, result}).

notify(Ref, Pid, Result) when is_pid(Pid) ->
    notify(Ref, [Pid], Result);
notify(_, [], _) ->
    ok;
notify(Ref, [P|T], Result) ->
    P ! {future, Ref, Result},
    notify(Ref, T, Result).

do_exec(Pid, Ref, Fun) ->
    Self = #future{pid = Pid, ref = Ref},
    spawn_link(fun() ->
                       try
                           Res = Fun(),
                           Self:set(Res)
                       catch
                           Class:Error ->
                               Self:error(Class, Error, erlang:get_stacktrace())
                       end
               end).

loop(Ref, Waiting, undefined) ->
    receive
        {execute, Ref, Fun} ->
            do_exec(self(), Ref, Fun),
            loop(Ref, Waiting, undefined);
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

execute(Fun, #future{pid = Pid, ref = Ref} = Self) ->
    Pid ! {execute, Ref, Fun},
    Self.

new(Future) when ?is_future(Future) ->
    Future;

new(Fun) when is_function(Fun, 0) ->
    Ref = make_ref(),
    Pid = spawn_link(fun() ->
                             do_exec(self(), Ref, Fun),
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

call(Self) ->
    Self:get().

get(#future{result = undefined} = Self) ->
    Self:attach(),
    Self:recv();
get(#future{result = {value, Value}}) ->
    Value.

recv(#future{ref = Ref} = _Self) ->
    receive
        {future, Ref, Res} ->
            handle(Res)
    end.

handle(Res) ->
    case Res of
        {value, Value} ->
            Value;
        {error, {Class, Error, ErrorStacktrace}} ->
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

map(Futures) ->
    new(fun() -> collect(Futures) end).

wrap([Initial0|List]) when ?is_futurable(Initial0) ->
    Initial = future:new(Initial0),
    lists:foldl(fun wrap/2, Initial, List).

wrap(Wrapper, Future0) when is_function(Wrapper, 1),
                            ?is_futurable(Future0) ->
    Future = future:new(Future0),
    future:new(fun() ->
                       R = Wrapper(Future),
                       Future:done(),
                       R
               end).

chain([C|List]) when is_list(List) ->
    Initial = future:new(C),
    lists:foldl(fun(S, Res) ->
                        chain(Res, S)
                end, Initial, List).

chain(C1, C2) when ?is_futurable(C1), is_function(C2, 1) ->
    F1 = future:new(C1),
    future:new(fun() ->
                       C2(F1:realize())
               end).

collect(Futures) ->
    [ F:attach() || F <- Futures ],
    Res = [ F:recv() || F <- Futures ],
    [ F:done() || F <- Futures ],
    Res.

cancel(#future{pid = Pid, ref = Ref} = F) ->
    Pid ! {cancel, Ref}, %% should do monitoring here to make sure it's dead
    F#future{pid = undefined, ref = Ref}.

%% =============================================================================
%%
%% Standard wrappers
%%
%% =============================================================================

%% Future to add:
%% 1. retries
%% 2. stats
%% 3. auth
%% 4. logging

timeout(F) ->
    timeout(F, 5000).
timeout(F, Timeout) ->
    wrap(fun(X) ->
                 Ref = X:attach(),
                 receive
                     {future, Ref, Res} ->
                         X:done(),
                         handle(Res)
                 after Timeout ->
                         X:cancel(),
                         throw(timeout)
                 end
         end, F).

safe(F) ->
    wrap(fun(X) ->
                 Ref = X:attach(),
                 receive
                     {future, Ref, Res} ->
                         X:done(),
                         case Res of
                             {value, Res} ->
                                 {ok, Res};
                             {error, {error, Error, _}} ->
                                 {error, Error};
                             {error, {exit, Error, _}} ->
                                 {error, Error};
                             {error, {throw, Error, _}} ->
                                 throw(Error)
                         end
                 after Timeout ->
                         X:cancel(),
                         throw(timeout)
                 end
         end, F).

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
