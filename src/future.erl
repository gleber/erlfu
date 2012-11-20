-module(future).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([%% creating
         new/0, new/1, static/1, static_error/1, static_error/2, static_error/3,

         %% manipulating
         set/2, error/2, error/3, error/4, execute/2,
         clone/1,

         %% getting
         get/1, realize/1, ready/1, call/1,
         attach/1, recv/1,

         %% finishing
         done/1, cancel/1]).

%% collections
-export([collect/1, map/1, chain/1, chain/2, wrap/1, wrap/2]).

%% wrappers
-export([timeout/1, timeout/2, safe/1, catcher/1, retry/1, retry/2]).

-define(is_future(F), is_record(F, future)).
-define(is_futurable(F), (?is_future(F) orelse is_function(F, 0))).

-record(future, {proc, ref, result}).
-record(state, {ref, waiting = [], exec, result, worker}).

notify(Ref, Pid, Result) when is_pid(Pid) ->
    notify(Ref, [Pid], Result);
notify(_, [], _) ->
    ok;
notify(Ref, [P|T], Result) ->
    P ! {future, Ref, Result},
    notify(Ref, T, Result).

do_exec(Ref, Fun) ->
    Pid = self(),
    spawn_monitor(fun() ->
                          try
                              Res = Fun(),
                              Pid ! {computed, Ref, {value, Res}}
                          catch
                              Class:Error ->
                                  Pid ! {computed, Ref, {error, {Class, Error, erlang:get_stacktrace()}}}
                          end
                  end).

%% loop(#state{result = {lazy, Fun}} = State) ->
%%     %% implement:
%%     %% - cancel
%%     %% - get
%%     %% - ready
%%     %% drop:
%%     %% - execute
%%     %% - set
%%     ok;

loop(#state{ref = Ref, waiting = Waiting, result = undefined, worker = Worker, exec = Exec} = State) ->
    receive
        {get_info, Ref, Requester} ->
            Requester ! {future_info, Ref, undefined, Exec},
            loop(State);
        {cancel, Ref} ->
            case Worker of
                undefined -> ok;
                {Pid, MonRef} ->
                    exit(Pid, kill),
                    receive
                        {'DOWN', MonRef, process, Pid, _} -> ok
                    end
            end,
            ok;
        {execute, Ref, Fun} ->
            case Worker of
                undefined ->
                    NewWorker = do_exec(Ref, Fun),
                    loop(State#state{worker = NewWorker, exec = Fun});
                _ ->
                    loop(State)
            end;
        {computed, Ref, Result} ->
            notify(Ref, Waiting, Result),
            {Pid, MonRef} = Worker,
            receive
                {'DOWN', MonRef, process, Pid, _} -> ok
            end,
            loop(State#state{waiting = [], result = Result, worker = undefined});
        {set, Ref, Result} ->
            case Worker of
                undefined ->
                    notify(Ref, Waiting, Result),
                    loop(State#state{waiting = [], result = Result});
                _ ->
                    loop(State)
            end;
        {ready, Ref, Requester} ->
            Requester ! {future_ready, Ref, false},
            loop(State);
        {get, Ref, Requester} ->
            loop(State#state{waiting = [Requester | Waiting]})
    end;

loop(#state{ref = Ref, waiting = [], result = {Type, _Value} = Result, worker = undefined, exec = Exec} = State) when Type /= lazy ->
    receive
        {get_info, Ref, Requester} ->
            Requester ! {future_info, Ref, Result, Exec},
            loop(State);
        {cancel, Ref} ->
            ok;
        {done, Ref} ->
            ok;
        {execute, Ref, _} -> loop(State); %% futures can be bound only once
        {computed, Ref, _} -> exit(bug);  %% futures can be bound only once
        {set, Ref, _} -> loop(State);     %% futures can be bound only once
        {ready, Ref, Requester} ->
            Requester ! {future_ready, Ref, true},
            loop(State);
        {get, Ref, Requester} ->
            notify(Ref, Requester, Result),
            loop(State)
    end.

execute(Fun, #future{proc = Proc, ref = Ref} = Self) ->
    Proc:send({execute, Ref, Fun}),
    Self.

static(Term) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                                loop(#state{ref = Ref, result = {value, Term}})
                        end),
    #future{proc = Proc, ref = Ref}.

static_error(Error) ->
    static_error(error, Error).

static_error(Class, Error) ->
    static_error(Class, Error, []).

static_error(Class, Error, Stack) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                               loop(#state{ref = Ref, result = {error, {Class, Error, Stack}}})
                       end),
    #future{proc = Proc, ref = Ref}.

new(Future) when ?is_future(Future) ->
    Future;

new(Fun) when is_function(Fun, 0) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                               W = do_exec(Ref, Fun),
                               loop(#state{ref = Ref, worker = W, exec = Fun})
                       end),
    #future{proc = Proc, ref = Ref}.

new() ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                               loop(#state{ref = Ref})
                       end),
    #future{proc = Proc, ref = Ref}.

clone(#future{proc = Proc, ref = Ref}) -> %% does not clone multi-level futures!!!
    Proc:send({get_info, Ref, self()}),
    receive
        {future_info, Ref, undefined, undefined} ->
            future:new();
        {future_info, Ref, _, Fun} when is_function(Fun) ->
            future:new(Fun);
        {future_info, Ref, {value, Result}, undefined} ->
            future:static(Result);
        {future_info, Ref, {error, {Class, Error, Stack}}, undefined} ->
            future:static_error(Class, Error, Stack)
    end.

error(Error, #future{} = Self) ->
    Self:error(error, Error).
error(Class, Error, #future{} = Self) ->
    Self:error(Class, Error, []).

error(Class, Error, Stacktrace, #future{proc = Proc, ref = Ref} = Self) ->
    Val = {error, {Class, Error, Stacktrace}},
    Proc:send({set, Ref, Val}),
    Self#future{result = Val}.

set(Value, #future{proc = Proc, ref = Ref} = Self) ->
    Proc:send({set, Ref, {value, Value}}),
    Self#future{result = {value, Value}}.

done(#future{proc = Proc, ref = Ref} = _Self) ->
    Proc:send({done, Ref}),
    ok.

realize(#future{} = Self) ->
    Ref = Self:attach(),
    Res = receive
              {future, Ref, R} ->
                  R
          end,
    Self:done(),
    Self#future{proc = undefined, ref = undefined, result = Res}.

call(Self) ->
    Self:get().

get(#future{result = undefined} = Self) ->
    Self:attach(),
    Self:recv();
get(#future{result = Res}) ->
    handle(Res).

recv(#future{ref = Ref} = _Self) ->
    receive
        {future, Ref, Res} ->
            handle(Res)
    end.

handle(Res) ->
    case Res of
        {value, Value} ->
            Value;
        {error, {_Class, _Error, _ErrorStacktrace} = E} ->
            reraise(E)
    end.

reraise({Class, Error, ErrorStacktrace}) ->
    {'EXIT', {new_stacktrace, CurrentStacktrace}} = (catch error(new_stacktrace)),
    erlang:raise(Class, Error, ErrorStacktrace ++ CurrentStacktrace).

attach(#future{proc = Proc, ref = Ref, result = undefined} = _Self) ->
    Proc:link(), %% should be monitor
    Proc:send({get, Ref, self()}),
    Ref;
attach(#future{ref = Ref, result = {_Type, _Value} = Result} = _Self) ->
    self() ! {future, Ref, Result},
    Ref.

ready(#future{result = {_Type, _Value}}) ->
    true;
ready(#future{proc = Proc, ref = Ref, result = undefined} = _Self) ->
    Proc:send({ready, Ref, self()}),
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

cancel(#future{proc = Proc, ref = Ref} = F) ->
    Proc:send({cancel, Ref}), %% should do monitoring here to make sure it's dead
    F#future{proc = undefined, ref = Ref}.

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

retry(F) ->
    retry(F, 3).
retry(F, Count) ->
    wrap(fun(X) ->
                 retry_wrapper(X, 0, Count)
         end, F).

retry_wrapper(_X, {C,E,S}, Max, Max) ->
    reraise({error, {retry_limit_reached, Max, {C,E}}, S});
retry_wrapper(X, _E, C, Max) ->
    retry_wrapper(X, C, Max).

retry_wrapper(X, Count, Max) ->
    Ref = X:attach(),
    receive
        {future, Ref, Res} ->
            case Res of
                {value, R} ->
                    X:done(),
                    R;
                {error, {throw, Error, _}} ->
                    throw(Error);
                {error, {_, _, _} = E} ->
                    Clone = X:clone(),
                    X:done(),
                    retry_wrapper(Clone, E, Count + 1, Max)
            end
    end.

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
                             {value, R} ->
                                 {ok, R};
                             {error, {error, Error, _}} ->
                                 {error, Error};
                             {error, {exit, Error, _}} ->
                                 {error, Error};
                             {error, {throw, Error, _}} ->
                                 throw(Error)
                         end
                 end
         end, F).

catcher(F) ->
        wrap(fun(X) ->
                     Ref = X:attach(),
                     receive
                         {future, Ref, Res} ->
                             X:done(),
                             case Res of
                                 {value, R} ->
                                     {ok, R};
                                 {error, {Class, Error, _}} ->
                                     {error, Class, Error}
                             end
                     end
             end, F).


%% =============================================================================
%%
%% Tests
%%
%% =============================================================================

-define(QC(Arg), proper:quickcheck(Arg, [])).


prop_basic() ->
    ?FORALL(X, term(),
            begin
                F = future:new(),
                F:set(X),
                Val = F:get(),
                F:done(),
                X == Val
            end).

basic_test() ->
    {timeout, 100, fun() ->
                           true = ?QC(future:prop_basic())
                   end}.

get_test() ->
    ok = application:start(gcproc),
    ok = application:start(erlfu),
    F = future:new(),
    F:set(42),
    Val = F:get(),
    F:done(),
    42 == Val.

realize_test() ->
    F = future:new(),
    F:set(42),
    F2 = F:realize(),
    42 == F2:get().

clone_val_test() ->
    F = future:new(),
    F:set(42),
    F2 = F:clone(),
    F:done(),
    F3 = F2:realize(),
    42 == F3:get().

clone_fun_test() ->
    F = future:new(fun() ->
                           43
                   end),
    F2 = F:clone(),
    F:done(),
    F3 = F2:realize(),
    43 == F3:get().

cancel_test() ->
    Self = self(),
    F = future:new(fun() ->
                           timer:sleep(1000),
                           exit(Self, kill),
                           42
                   end),
    F:cancel(),
    timer:sleep(50),
    true.

safe_ok_test() ->
    F = future:new(fun() ->
                           1
                   end),
    F2 = future:safe(F),
    F3 = F2:realize(),
    ?assertEqual({ok, 1}, F3:get()).

safe_err_test() ->
    F = future:new(fun() ->
                           error(1)
                   end),
    F2 = future:safe(F),
    F3 = F2:realize(),
    ?assertEqual({error, 1}, F3:get()).

timeout_test() ->
    F = future:new(fun() ->
                           timer:sleep(1000),
                           done
                   end),
    F2 = future:timeout(F, 100),
    F3 = F2:realize(),
    ?assertException(throw, timeout, F3:get()).

safe_timeout_test() ->
    F = future:new(fun() ->
                           timer:sleep(1000),
                           done
                   end),
    F2 = future:safe(future:timeout(F, 100)),
    F3 = F2:realize(),
    ?assertException(throw, timeout, F3:get()).

c4tcher_timeout_test() -> %% seems like 'catch' in the function name screwes up emacs erlang-mode indentation
    F = future:new(fun() ->
                           timer:sleep(1000),
                           done
                   end),
    F2 = future:catcher(future:timeout(F, 100)),
    F3 = F2:realize(),
    ?assertEqual({error, throw, timeout}, F3:get()).

retry_success_test() ->
    T = ets:new(retry_test, [public]),
    ets:insert(T, {counter, 4}),
    F = future:new(fun() ->
                           Val = ets:update_counter(T, counter, -1),
                           0 = Val,
                           Val
                   end),
    F2 = future:retry(F, 5),
    F3 = F2:realize(),
    ?assertEqual(0, F3:get()).

retry_fail_test() ->
    T = ets:new(retry_test, [public]),
    ets:insert(T, {counter, 4}),
    F = future:new(fun() ->
                           Val = ets:update_counter(T, counter, -1),
                           0 = Val,
                           Val
                   end),
    F2 = future:retry(F, 3),
    F3 = F2:realize(),
    ?assertException(error, {retry_limit_reached, 3, _}, F3:get()).
