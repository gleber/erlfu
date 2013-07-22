-module(future).

-export([%% creating
         new/0,        %% creates unbounded future
         new/1,        %% creates a future with a fun to compute
         new_static/1, %% creates a future with a static value
         new_static_error/1, new_static_error/2, new_static_error/3, %% creates a future with a static error

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
         as_fun/1,     %% returns fun, which wraps get/1

         %% finishing
         realize/1,    %% waits for future to compute, stops the future process and returns bounded local future
         done/1,       %% waits for future to compute and stops the future process
         cancel/1      %% cancels the future and stops the process
        ]).

%% collections
-export([collect/1,       %% collect values from multile futures
         combine/1,       %% combines multiple futures into a future which returns a list of values
         map/2,           %% maps multiple futures with a fun and returns combined future
         wrap/1, wrap/2,  %% wraps a future with a fun, returning wrapping future
         chain/1, chain/2 %% realizes a future and it with a fun, returning wrapping future
        ]).

%% wrappers
-export([timeout/1, %% limits future time-to-bound to 5000ms
         timeout/2, %% as above, with configurable timeout
         safe/1,    %% catches errors and exceptions
         catcher/1, %% catches errors, exceptions and throws
         retry/1, retry/2 %% retries on errors (3 times by default)
        ]).

-define(is_future(F), is_record(F, future)).
-define(is_futurable(F), (?is_future(F) orelse is_function(F, 0))).

-define(is_realized(F), (?is_future(F)
                         andalso (F#future.proc == undefined)
                         andalso (F#future.ref == undefined))).
-opaque future() :: tuple().
%% -type future() :: #future{}.
-type future_opt() :: {'wraps', future()}.
-type future_res() :: {'value', term()} |
                      {'error', {atom(), term(), list(term())}}.

-record(future, {proc        :: gcproc:gcproc(),
                 ref         :: reference(),
                 result      :: 'undefined' | future_res()}).

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
                                loop(#state{ref = Ref, worker = W, executable = Fun, opts = Opts})
                        end),
    #future{proc = Proc, ref = Ref};

new0(Fun, Opts) when is_function(Fun, 1) ->
    Ref = make_ref(),
    Wraps = proplists:get_value(wraps, Opts),
    true = (Wraps /= undefined),
    Proc = gcproc:spawn(fun() ->
                                W = do_exec(Ref, Fun, [Wraps]),
                                loop(#state{ref = Ref, worker = W, executable = Fun, opts = Opts})
                        end),
    #future{proc = Proc, ref = Ref}.

new_static(Term) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                                loop(#state{ref = Ref, result = {value, Term}})
                        end),
    #future{proc = Proc, ref = Ref}.

new_static_error(Error) ->
    new_static_error(error, Error).

new_static_error(Class, Error) ->
    new_static_error(Class, Error, []).

new_static_error(Class, Error, Stack) ->
    Ref = make_ref(),
    Proc = gcproc:spawn(fun() ->
                                loop(#state{ref = Ref, result = {error, {Class, Error, Stack}}})
                        end),
    #future{proc = Proc, ref = Ref}.

execute(Fun, #future{proc = Proc, ref = Ref} = Self) when is_function(Fun, 0) ->
    Proc:send({execute, Ref, Fun}), %% should crash calling process if future is bound
    Self.

clone(#future{proc = Proc, ref = Ref}) -> %% does not clone multi-level futures!!!
    Proc:send({get_info, Ref, self()}),
    receive
        %% future_info, Ref, Result, Executable, Wraps
        {future_info, Ref, undefined, undefined, undefined} ->
            %% io:format("Cloning empty future~n"),
            new();
        {future_info, Ref, {value, Result}, undefined, undefined} ->
            %% io:format("Cloning static val future~n"),
            new_static(Result);
        {future_info, Ref, {error, {Class, Error, Stack}}, undefined, undefined} ->
            %% io:format("Cloning static error future~n"),
            new_static_error(Class, Error, Stack);
        {future_info, Ref, _, Fun, undefined} when is_function(Fun) ->
            %% io:format("Cloning fun ~p future~n", [erlang:fun_info(Fun)]),
            new(Fun);
        {future_info, Ref, _, Fun, Wraps} when is_function(Fun), ?is_future(Wraps) ->
            %% io:format("Cloning fun ~p future which wraps ~p~n", [erlang:fun_info(Fun), Wraps]),
            Wraps2 = Wraps:clone(),
            wrap(Fun, Wraps2)
    end.

set_error(Error, #future{} = Self) ->
    Self:error(error, Error).
set_error(Class, Error, #future{} = Self) ->
    Self:error(Class, Error, []).

set_error(Class, Error, Stacktrace, #future{proc = Proc, ref = Ref} = Self) ->
    Err = {Class, Error, Stacktrace},
    Proc:send({set, Ref, {error, Err}}),
    Self#future{result = {error, Err}}.

set(Value, #future{proc = Proc, ref = Ref} = Self) ->
    Proc:send({set, Ref, {value, Value}}),
    Self#future{result = {value, Value}}.

done(#future{proc = Proc, ref = Ref} = _Self) ->
    %% Let future process know it should finish as soon as it is done
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
ready(#future{proc = Proc, ref = Ref, result = undefined} = _Self) ->
    Proc:send({ready, Ref, self()}),
    %%TODO: should monitor a future process
    receive
        {future_ready, Ref, Ready} ->
            Ready
    end.

combine(Futures) ->
    new(fun() -> collect(Futures) end).

map(Fun, Futures) ->
    new(fun() ->
                Fs = [ wrap(Fun, F) || F <- Futures ],
                collect(Fs)
        end).

wrap([Initial0|List]) when ?is_futurable(Initial0) ->
    Initial = new(Initial0),
    lists:foldl(fun wrap/2, Initial, List).

wrap(Wrapper, Future0) when is_function(Wrapper),
                            ?is_futurable(Future0) ->
    {wrapper_arity_1, true, _} = {wrapper_arity_1, is_function(Wrapper, 1), erlang:fun_info(Wrapper)},
    Future = new(Future0),
    new0(fun() ->
                 R = Wrapper(Future),
                 %% Future:done(),
                 R
         end,
         [{wraps, Future}]).

chain([C|List]) when is_list(List) ->
    Initial = new(C),
    lists:foldl(fun(S, Res) ->
                        chain(Res, S)
                end, Initial, List).

chain(C1, C2) when ?is_futurable(C1), is_function(C2, 1) ->
    chain0(C1, C2, []).

collect(Futures) ->
    L = [ {F, attach(F)} || F <- Futures ],
    Res = [ do_detach(Attach, F) || {F, Attach} <- L ],
    %% [ F:done() || F <- Futures ],
    [ handle(R) || R <- Res ].

cancel(#future{proc = Proc, ref = Ref} = F) ->
    Proc:send({cancel, Ref}), %% should do monitoring here to make sure it's dead
    F#future{proc = undefined, ref = Ref}.


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
                 %% do_detach is done below
                 receive
                     {future, Ref, Res} ->
                         case Mon of
                             undefined -> ok;
                             _         -> Proc:demonitor(Mon)
                         end,
                         %% X:done(),
                         handle(Res);
                     {'DOWN', Mon, process, _Pid, Reason} ->
                         reraise_down_reason(Reason)
                 after Timeout ->
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

        {execute, Ref, Fun} ->
            case Worker of
                undefined ->
                    NewWorker = do_exec(Ref, Fun, []),
                    loop0(State#state{worker = NewWorker, executable = Fun});
                _ ->
                    loop0(State) %%TODO: crash calling process with future_already_bound
            end;

        {computed, Ref, Result} ->
            notify(Ref, Waiting, Result),
            {Pid, MonRef} = Worker,
            receive
                {'DOWN', MonRef, process, Pid, _} -> ok
            end,
            loop0(State#state{waiting = [], result = Result, worker = undefined});

        {set, Ref, Result} ->
            case Worker of
                undefined ->
                    notify(Ref, Waiting, Result),
                    loop0(State#state{waiting = [], result = Result});
                _ ->
                    loop0(State)
            end;

        {ready, Ref, Requester} ->
            Requester ! {future_ready, Ref, false},
            loop0(State);

        {get, Ref, Requester} ->
            loop0(State#state{waiting = [Requester | Waiting]})
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
        {cancel, Ref}      -> ok;
        {done, Ref}        -> ok;           %% upon receiving done bounded future terminates
        {execute, Ref, _}  -> loop0(State); %% futures can be bound only once
        {computed, Ref, _} -> exit(bug);    %% futures can be bound only once
        {set, Ref, _}      -> loop0(State); %% futures can be bound only once
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

%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% API helpers
%%
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

do_get(#future{result = Res} = Self) when ?is_realized(Self) ->
    Res;
do_get(#future{} = Self) ->
    Att = attach(Self),
    do_detach(Att, Self).

attach(#future{proc = Proc, ref = Ref, result = undefined} = _Self) ->
    Mon = Proc:monitor(),
    Proc:send({get, Ref, self()}),
    {Ref, Mon};
attach(#future{ref = Ref, result = {_Type, _Value} = Result} = _Self) ->
    self() ! {future, Ref, Result},
    {Ref, undefined}.

%% detach(Att, Self) ->
%%     handle(do_detach(Att, Self)).

do_detach({Ref, Mon}, #future{ref = Ref, proc = Proc} = _Self) ->
    receive
        {future, Ref, Res} ->
            case Mon of
                undefined -> ok;
                _         -> Proc:demonitor(Mon)
            end,
            Res;
        {'DOWN', Mon, process, _Pid, Reason} ->
            reraise_down_reason(Reason)
    end.

handle(Result) ->
    case Result of
        {value, Value} ->
            Value;
        {error, {_Class, _Error, _ErrorStacktrace} = E} ->
            reraise(E)
    end.

reraise({Class, Error, ErrorStacktrace}) ->
    {'EXIT', {get_stacktrace, CurrentStacktrace}} = (catch error(get_stacktrace)),
    erlang:raise(Class, Error, ErrorStacktrace ++ CurrentStacktrace).

reraise_down_reason(Reason) ->
    case Reason of
        {{nocatch,Error},Stack} ->
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
