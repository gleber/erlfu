-module(future).

-export([%% creating
         new/0,        %% creates unbounded future
         new/1,        %% creates a future with a fun to compute
         new_static/1, %% creates a future with a static value
         new_static_error/1, new_static_error/2, new_static_error/3, %% creates a future with a static error

         wait_for/1,   %% bounds to process termination reason
         on_done/2,    %% executes fun() upon execution of future() (or when it's bound)
         on_success/2, %% executes fun() upon successful execution of future()
         on_failure/2, %% executes fun() upon failed execution (i.e. execution
         %%               failed with error or exit) of future()

         %% manipulating; all these will fail if future is already bound
         set/2,        %% sets value of a future to a term
         set_error/2,  %% sets value of a future to an error
         set_error/3,  %% as above
         set_error/4,  %% as above
         execute/2,    %% tells future to execute a fun and set it's own value,
         clone/1,      %% clones a future (clone properly clones deeply wrapped futures)

         %% getting
         ready/1,      %% returns true if future is bounded
         get/1,        %% waits for future to compute and returns the value
         call/1,       %% the same as get/1
         as_fun/1,     %% returns fun, which returns the same value as get/1

         %% finishing
         realize/1,    %% waits for future to compute, stops the future process and returns bounded local future
         done/1,       %% waits for future to compute and stops the future process
         cancel/1      %% cancels the future and stops the process
        ]).

%% collections
-export([select/1,        %% finds first available future among provided futures
         select_value/1,  %% value of the above

         select_full/1,   %% returns first available future among provided futures,
         %%                  list of already failed futures and list
         %%                  of not-yet-responded futures
         select_full_value/1, %% value of the above

         combine/1,       %% combines multiple futures into a future which returns a list of values
         combine_value/1, %% value of the above

         map/2,           %% maps multiple futures with a fun and returns combined future
         wrap/1, wrap/2,  %% returns a future, which wraps argument future with a fun
         chain/1, chain/2 %% returns a future, which realizes argument future and wraps it with a fun
        ]).

%% wrappers
-export([timeout/1, %% limits future time-to-bound to 5000ms
         timeout/2, %% as above, with configurable timeout
         safe/1,    %% catches errors and exceptions
         catcher/1, %% catches errors, exceptions and throws
         retry/1, retry/2 %% retries on errors (3 times by default)
        ]).

%% low level functions - useful for implementing compositions
-export([ref/1,    %% returns future reference
         proc/1,   %% returns future's process as a gcproc
         attach/1, %% attaches process to a future, which results in a message
         %%           {future, reference(), future_res()} sent to self
         %%           and returns future_attachment()

         detach/2, %% detach/2 will consume the message from the future based on
         %%           future_attachment(), and returns future_res()

         handle/1  %% handles future_res(), returns appropriate value or raises appropriate exception
        ]).

-include_lib("erlfu/include/erlfu.hrl").

-type future_opt() :: {'wraps', future()}.

-record(state, {ref          :: reference(),
                waiting = [] :: list(pid()),
                executable   :: 'undefined' | pid(),
                result       :: 'undefined' | future_res(),
                worker       :: 'undefined' | pid(),
                opts    = [] :: list(future_opt())}).

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% API: basics
%%
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new() ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                                loop(#state{ref = Ref})
                        end),
    #future{proc = Proc, ref = Ref}.

new(Future) ->
    new0(Future, []).

new0(Future, []) when ?is_future(Future) ->
    Future;

new0(Fun, Opts) when is_function(Fun, 0) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                                W = do_exec(Ref, Fun, []),
                                loop(#state{ref = Ref,
                                            worker = W,
                                            executable = Fun,
                                            opts = Opts})
                        end),
    #future{proc = Proc, ref = Ref};

new0(Fun, Opts) when is_function(Fun, 1) ->
    Ref = make_ref(),
    Wraps = proplists:get_value(wraps, Opts),
    true = (Wraps /= undefined),
    Proc = gcproc:spawn(fun() ->
                                W = do_exec(Ref, Fun, [Wraps]),
                                loop(#state{ref = Ref,
                                            worker = W,
                                            executable = Fun,
                                            opts = Opts})
                        end),
    #future{proc = Proc, ref = Ref}.

new_static(Term) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                                loop(#state{ref = Ref,
                                            result = {value, Term}})
                        end),
    #future{proc = Proc, ref = Ref}.

new_static_error(Error) ->
    new_static_error(error, Error).

new_static_error(Class, Error) ->
    new_static_error(Class, Error, []).

new_static_error(Class, Error, Stack) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                                loop(#state{ref = Ref,
                                            result = {error, {Class, Error, Stack}}})
                        end),
    #future{proc = Proc, ref = Ref}.

execute(Fun, #future{ref = Ref} = Self) when is_function(Fun, 0) ->
    do_call(Self, {execute, Ref, self(), Fun}, executing),
    Self.

set_error(Error, #future{} = Self) ->
    Self:set_error(error, Error).
set_error(Class, Error, #future{} = Self) ->
    Self:set_error(Class, Error, []).

set_error(Class, Error, Stacktrace, #future{ref = Ref} = Self) ->
    Err = {Class, Error, Stacktrace},
    do_call(Self, {set, Ref, self(), {error, Err}}, set),
    Self#future{result = {error, Err}}.

set(Value, #future{ref = Ref} = Self) ->
    do_call(Self, {set, Ref, self(), {value, Value}}, set),
    Self#future{result = {value, Value}}.

done(#future{proc = Proc, ref = Ref} = _Self) ->
    %% Let future process know it should terminate gracefully as soon as it is done
    Proc:send({done, Ref}),
    ok.

realize(#future{} = Self) when ?is_realized(Self) ->
    Self; %% realizing already realized future yields no changes

realize(#future{} = Self) ->
    Res = do_get(Self),
    Self:done(),
    Self#future{proc = undefined, ref = undefined, result = Res}.

call(Self) ->
    Self:get().

get(#future{} = Self) ->
    handle(do_get(Self)).

as_fun(Self) ->
    fun() -> Self:get() end.

ready(#future{result = {_Type, _Value}}) ->
    true;
ready(#future{ref = Ref, result = undefined} = Self) ->
    case do_call(Self, {ready, Ref, self()}, future_ready) of
        {future_ready, Ref, Ready} ->
            Ready
    end.

cancel(#future{proc = Proc, ref = Ref} = F) ->
    Mon = Proc:monitor(),
    Proc:send({cancel, Ref}),
    receive
        {'DOWN', Mon, process, _Pid, normal} -> ok
    end,
    Proc:demonitor(Mon),
    F#future{proc = undefined, ref = Ref}.

clone(#future{ref = Ref} = Self) ->
    Info = do_call(Self, {get_info, Ref, self()}, future_info),
    case Info of
        %% future_info, Ref, Result, Executable, Wraps
        {future_info, Ref, undefined, undefined, undefined} ->
            new();
        {future_info, Ref, {value, Result}, undefined, undefined} ->
            new_static(Result);
        {future_info, Ref, {error, {Class, Error, Stack}}, undefined, undefined} ->
            new_static_error(Class, Error, Stack);
        {future_info, Ref, _, Fun, undefined} when is_function(Fun) ->
            new(Fun);
        {future_info, Ref, _, Fun, Wraps}
          when is_function(Fun), ?is_future(Wraps) ->
            Wraps2 = Wraps:clone(),
            wrap(Fun, Wraps2);
        {future_info, Ref, _, Fun, ListOfWraps}
          when is_function(Fun), is_list(ListOfWraps) ->
            ListOfWraps2 = [ X:clone() || X <- ListOfWraps ],
            wrap(Fun, ListOfWraps2)
    end.

wait_for(Proc) when element(1, Proc) == gcproc ->
    new(fun() ->
                Mon = Proc:monitor(),
                receive
                    {'DOWN', Mon, process, _Pid, Reason} ->
                        Reason
                end
        end);
wait_for(Pid) when is_pid(Pid) ->
    new(fun() ->
                Mon = erlang:monitor(process, Pid),
                receive
                    {'DOWN', Mon, process, Pid, Reason} ->
                        Reason
                end
        end).

on_done(F, Future) when is_function(F, 1), ?is_future(Future) ->
    wrap(fun(X) ->
                 {ok, F(X:get())}
         end, catcher(Future)).

on_success(F, Future) when is_function(F, 1), ?is_future(Future) ->
    wrap(fun(X) ->
                 case X:get() of
                     {ok, Value} ->
                         {ok, F(Value)};
                     _ -> {error, failed}
                 end
         end, catcher(Future)).

on_failure(F, Future) when is_function(F, 1), ?is_future(Future) ->
    wrap(fun(X) ->
                 case X:get() of
                     {ok, _Value} ->
                         {error, succeeded};
                     {error, Error} ->
                         {ok, F(Error)}
                 end
         end, catcher(Future)).

wrap([Initial0|List]) when ?is_futurable(Initial0) ->
    Initial = new(Initial0),
    lists:foldl(fun wrap/2, Initial, List).

wrap(Wrapper, Futures0) when is_function(Wrapper),
                             is_list(Futures0) ->
    {wrapper_arity_1, true, _} = {wrapper_arity_1, is_function(Wrapper, 1), erlang:fun_info(Wrapper)},
    Futures = [ new(X) || X <- Futures0 ],
    new0(fun(X) ->
                 Wrapper(X) %%X:done()
         end,
         [{wraps, Futures}]);
wrap(Wrapper, Future0) when is_function(Wrapper),
                            ?is_futurable(Future0) ->
    {wrapper_arity_1, true, _} = {wrapper_arity_1, is_function(Wrapper, 1), erlang:fun_info(Wrapper)},
    Future = new(Future0),
    new0(fun(X) ->
                 Wrapper(X) %%X:done()
         end,
         [{wraps, Future}]).

chain([C|List]) when is_list(List) ->
    Initial = new(C),
    lists:foldl(fun(S, Res) ->
                        chain(Res, S)
                end, Initial, List).

chain(C1, C2) when ?is_futurable(C1), is_function(C2, 1) ->
    chain0(C1, C2, []).

map(Fun, Futures) ->
    new0(fun(X) ->
                 Fs = [ wrap(Fun, F) || F <- X ],
                 do_collect(Fs)
         end,
         [{wraps, Futures}]).

combine(Futures) ->
    new0(fun(X) ->
                 do_collect(X)
         end,
         [{wraps, Futures}]).

combine_value(Futures) ->
    F = combine(Futures),
    F:get().

select_full(Futures) ->
    new0(fun() ->
                 do_select_any(Futures)
         end,
         [{wraps, Futures}]).

select_full_value(Futures) ->
    F = select_full(Futures),
    F:get().

select(Futures) ->
    new0(fun() ->
                 {F, _, _} = do_select_any(Futures),
                 F
         end,
         [{wraps, Futures}]).

select_value(Futures) ->
    F = select(Futures),
    F:get().

proc(Self) ->
    Self#future.proc.

ref(Self) ->
    Self#future.ref.

%% =============================================================================
%%
%% API: Standard wrappers
%%
%% =============================================================================

%% Future to add:
%% 1. DONE retries
%% 2. stats
%% 3. auth
%% 4. logging

retry(F) ->
    retry(F, 3).
retry(F, Count) ->
    wrap(fun(X) ->
                 retry_wrapper(X, 0, Count)
         end, F).

timeout(F) ->
    timeout(F, 5000).
timeout(F, Timeout) ->
    wrap(fun(#future{proc = Proc} = X) ->
                 {Ref, Mon} = attach(X),
                 %% unwrapped do_detach is done below
                 receive
                     {future, Ref, Res} ->
                         case Mon of
                             undefined -> ok;
                             _         -> Proc:demonitor(Mon)
                         end,
                         %% X:done(),
                         handle(Res);
                     {'DOWN', Mon, process, _Pid, Reason} ->
                         Proc:demonitor(Mon),
                         reraise_down_reason(Reason)
                 after Timeout ->
                         Proc:demonitor(Mon),
                         X:cancel(),
                         throw(timeout)
                 end
         end, F).

safe(F) ->
    wrap(fun(X) ->
                 Res = do_get(X),
                 %% X:done(),
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
         end, F).

catcher(F) ->
        wrap(fun(X) ->
                     Res = do_get(X),
                     %% X:done(),
                     case Res of
                         {value, R} ->
                             {ok, R};
                         {error, {Class, Error, _}} ->
                             {error, Class, Error}
                     end
             end, F).


%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Internal: loops and functions
%%
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

loop(State) ->
    %% erlang:process_flag(trap_exit, true),
    loop0(State).

%% loop0(#state{result = {lazy, Fun}} = State) ->
%%     %% implement:
%%     %% - cancel
%%     %% - get
%%     %% - ready
%%     %% drop:
%%     %% - execute
%%     %% - set
%%     ok;

%% loop of an unbounded future
loop0(#state{ref = Ref,
             waiting = Waiting,
             result = undefined,
             worker = Worker,
             executable = Exec,
             opts = Opts} = State) ->
    {WorkerPid, WorkerMon} = case Worker of
                                 {_,_} -> Worker;
                                 undefined -> {undefined, undefined}
                             end,
    receive
        {get_info, Ref, Requester} ->
            Requester ! {future_info, Ref,
                         undefined, Exec,
                         proplists:get_value(wraps, Opts)},
            loop0(State);

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

        {execute, Ref, Caller, Fun} ->
            case Worker of
                undefined ->
                    Caller ! {executing, Ref},
                    NewWorker = do_exec(Ref, Fun, []),
                    loop0(State#state{worker = NewWorker, executable = Fun});
                _ ->
                    Caller ! {'EXIT', executing, Ref, badfuture},
                    loop0(State)
            end;

        {computed, Ref, Result} ->
            notify(Ref, Waiting, Result),
            receive
                {'DOWN', WorkerMon, process, WorkerPid, _} -> ok
            end,
            loop0(State#state{waiting = [], result = Result, worker = undefined});

        {set, Ref, Caller, Result} ->
            case Worker of
                undefined ->
                    Caller ! {set},
                    notify(Ref, Waiting, Result),
                    loop0(State#state{waiting = [], result = Result});
                _ ->
                    Caller ! {'EXIT', set, Ref, badfuture},
                    loop0(State)
            end;

        {ready, Ref, Requester} ->
            Requester ! {future_ready, Ref, false},
            loop0(State);

        {get, Ref, Requester} ->
            loop0(State#state{waiting = [Requester | Waiting]});

        {'DOWN', WorkerMon, process, WorkerPid, Reason} ->
            reraise_down_reason(Reason)
    end;

%% loop of a bounded future
loop0(#state{ref = Ref,
             waiting = [],
             result = {Type, _Value} = Result,
             worker = undefined,
             executable = Exec,
             opts = Opts} = State) when Type /= lazy ->
    receive
        {get_info, Ref, Requester} ->
            Requester ! {future_info, Ref, Result, Exec, proplists:get_value(wraps, Opts)},
            loop0(State);
        {cancel, Ref} -> ok;
        {done, Ref}   -> ok;           %% upon receiving done bounded future terminates
        {execute, Ref, Caller, _Fun} ->
            Caller ! {'EXIT', executing, Ref, badfuture},
            loop0(State); %% futures can be bound only once
        {computed, Ref, _} -> exit(bug); %% futures can be bound only once
        {set, Ref, Caller, Result} ->
            Caller ! {set},
            loop0(State);
        {set, Ref, Caller, _V} ->
            Caller ! {'EXIT', executing, Ref, badfuture},
            loop0(State); %% futures can be bound only once
        {ready, Ref, Requester} ->
            Requester ! {future_ready, Ref, true},
            loop0(State);
        {get, Ref, Requester} ->
            notify(Ref, Requester, Result),
            loop0(State)
    end.


notify(Ref, Pid, Result) when is_pid(Pid) ->
    notify(Ref, [Pid], Result);
notify(_, [], _) ->
    ok;
notify(Ref, [P|T], Result) ->
    P ! {future, Ref, Result},
    notify(Ref, T, Result).

do_exec(Ref, Fun, Args) ->
    Pid = self(),
    spawn_monitor(
      fun() ->
              try
                  Res = apply(Fun, Args),
                  Pid ! {computed, Ref, {value, Res}}
              catch
                  Class:Error ->
                      Pid ! {computed, Ref, {error, {Class, Error, erlang:get_stacktrace()}}}
              end
      end).

do_call(#future{proc = Proc, ref = Ref}, Msg, RespTag) ->
    Mon = Proc:monitor(),
    Proc:send(Msg),
    receive
        Resp when is_tuple(Resp),
                  element(1, Resp) == 'EXIT';
                  element(2, Resp) == RespTag;
                  element(3, Resp) == Ref ->
            Proc:demonitor(Mon),
            erlang:error(element(4, Resp));
        Resp when is_tuple(Resp),
                  element(1, Resp) == RespTag;
                  element(2, Resp) == Ref ->
            Proc:demonitor(Mon),
            Resp;
        {'DOWN', Mon, process, _Pid, Reason} ->
            Proc:demonitor(Mon),
            reraise_down_reason(Reason)
    end.


%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% API helpers
%%
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


do_collect(Futures) ->
    L = [ {F, attach(F)} || F <- Futures ],
    Res = [ detach(Attach, F) || {F, Attach} <- L ],
    %% [ F:done() || F <- Futures ],
    [ handle(R) || R <- Res ].

do_select_any(Futures) ->
    L = [ {F, Ref, Mon} || F <- Futures,
                           {Ref, Mon} <- [attach(F)]],
    collector_any(L, []).

collector_any([], _) ->
    erlang:error(all_futures_failed);
collector_any(L, Failed) ->
    receive
        {future, Ref, Res} ->
            case Res of
                {value, _} ->
                    {value, {F, _, _}, L2} = lists:keytake(Ref, 2, L),
                    {F, Failed, L2};
                {error, _} ->
                    {value, {F, _, _}, L2} = lists:keytake(Ref, 2, L),
                    collector_any(L2, [F|Failed])
            end;
        {'DOWN', Mon, process, _Pid, _Reason} ->
            {value, {F, _, _}, L2} = lists:keytake(Mon, 3, L),
            collector_any(L2, [F|Failed])
    end.

do_get(#future{result = Res} = Self) when ?is_realized(Self) ->
    Res;
do_get(#future{} = Self) ->
    Att = attach(Self),
    detach(Att, Self).

-spec attach(future()) -> future_attachment().
attach(#future{proc = Proc, ref = Ref, result = undefined} = _Self) ->
    Mon = Proc:monitor(),
    Proc:send({get, Ref, self()}),
    {Ref, Mon};
attach(#future{ref = Ref, result = {_Type, _Value} = Result} = _Self) ->
    self() ! {future, Ref, Result},
    {Ref, undefined}.

-spec detach(future_attachment(), future()) -> future_res().
detach({Ref, Mon}, #future{ref = Ref, proc = Proc} = _Self) ->
    receive
        {future, Ref, Res} ->
            case Mon of
                undefined -> ok;
                _         -> Proc:demonitor(Mon)
            end,
            Res;
        {'DOWN', Mon, process, _Pid, Reason} ->
            Proc:demonitor(Mon),
            reraise_down_reason(Reason)
    end.

handle({value, Value}) ->
    Value;
handle({error, {_Class, _Error, _ErrorStacktrace} = E}) ->
    reraise(E).

reraise({Class, Error, ErrorStacktrace}) ->
    {'EXIT', {get_stacktrace, CurrentStacktrace}} = (catch erlang:error(get_stacktrace)),
    erlang:raise(Class, Error, ErrorStacktrace ++ CurrentStacktrace).

reraise_down_reason(Reason) ->
    case Reason of
        {{nocatch, Error}, Stack} ->
            reraise({throw, Error, Stack});
        {Error,Stack} ->
            reraise({error, Error, Stack});
        Error ->
            reraise({exit, Error, []})
    end.

chain0(C1, C2, Opts) when ?is_futurable(C1), is_function(C2, 1) ->
    F1 = new(C1),
    new0(fun() ->
                 C2(F1:realize())
         end,
         [{wraps, F1}] ++ Opts).

retry_wrapper(_X, {C,E,S}, Max, Max) ->
    reraise({error, {retry_limit_reached, Max, {C,E}}, S});
retry_wrapper(X, _E, C, Max) ->
    retry_wrapper(X, C, Max).

retry_wrapper(X, Count, Max) ->
    Res = do_get(X), %% handle dead future
    case Res of
        {value, R} ->
            %% X:done(),
            R;
        {error, {throw, Error, _}} -> %% throw is a flow control tool, not an retry-able error
            throw(Error);
        {error, {_, _, _} = E} ->
            Clone = X:clone(),
            %% X:done(),
            retry_wrapper(Clone, E, Count + 1, Max)
    end.
