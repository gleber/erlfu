-module(future_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlfu/include/erlfu.hrl").


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
    erlfu:start(),
    F = future:new(),
    F:set(42),
    Val = F:get(),
    F:done(),
    ?assertEqual(42, Val).

double_set_good_test() ->
    F = future:new(),
    F:set(42),
    F:set(42),
    Val = F:get(),
    F:done(),
    ?assertEqual(42, Val).

double_set_bad_test() ->
    F = future:new(),
    F:set(42),
    ?assertException(error, badfuture, F:set(wontwork)).

realize_test() ->
    F = future:new(),
    F:set(42),
    F2 = F:realize(),
    ?assertEqual(42, F2:get()).

worker_killed_test() ->
    Fun = fun() ->
                  exit(self(), kill)
          end,
    F = future:new(Fun),
    ?assertException(exit, killed, F:get()).

future_killed_test() ->
    Fun = fun() ->
                  timer:sleep(100000)
          end,
    F = future:new(Fun),
    Proc = element(2, F),
    Pid = Proc:pid(),
    exit(Pid, kill),
    ?assertException(exit, killed, F:get()).

clone_val_test() ->
    F = future:new(),
    F:set(42),
    F2 = F:clone(),
    F:done(),
    F3 = F2:realize(),
    ?assertEqual(42, F3:get()).

clone_fun_test() ->
    F = future:new(fun() ->
                           43
                   end),
    F2 = F:clone(),
    F:done(),
    F3 = F2:realize(),
    ?assertEqual(43, F3:get()).

clone_deep_fun_test() ->
    F1 = future:new(fun() ->
                            1
                    end),
    ?assertEqual(1, F1:get()),
    F1C = F1:clone(),
    ?assertEqual(1, F1C:get()),
    F2 = future:wrap(fun(X) ->
                             X:get() + 2
                     end, F1),
    ?assertEqual(3, F2:get()),
    F2C = F2:clone(),
    ?assertEqual(3, F2C:get()),
    F3 = future:wrap(fun(Y) ->
                             Y:get() + 3
                     end, F2),
    ?assertEqual(6, F3:get()),
    F3C = F3:clone(),
    ?assertEqual(6, F3C:get()),
    F4 = future:wrap(fun(Z) ->
                             Z:get() + 4
                     end, F3),
    ?assertEqual(10, F4:get()),
    F4C = F4:clone(),
    ?assertEqual(10, F4C:get()),
    ok.

clone_clones_fun_test() ->
    F1 = future:new(fun() ->
                            1
                    end),
    F1C = F1:clone(),
    F2 = future:wrap(fun(X) ->
                             X:get() + 2
                     end, F1C),
    F2C = F2:clone(),
    F3 = future:wrap(fun(Y) ->
                             Y:get() + 3
                     end, F2C),
    F3C = F3:clone(),
    ?assertEqual(6, F3C:get()).

clone_combined_test() ->
    {messages, []} = process_info(self(), messages),
    Self = self(),
    F1 = future:new(fun() ->
                            Self ! 1
                    end),
    F2 = future:new(fun() ->
                            Self ! 2
                    end),
    F3 = future:combine([F1, F2]),
    ?assertEqual([1, 2], F3:get()),
    timer:sleep(100),
    %% we should have exactly two messages in the queue
    ?assertEqual({messages, [1,2]}, process_info(self(), messages)),
    F3C = F3:clone(),
    ?assertEqual([1, 2], F3C:get()),
    timer:sleep(100),
    %% we should have exactly six (three old plus three new) messages in the queue
    ?assertEqual({messages, [1,2,1,2]}, process_info(self(), messages)),
    flush(),
    ok.

clone_side_effect_fun_test() ->
    Self = self(),
    F1 = future:new(fun() ->
                            Self ! 1
                    end),
    F2 = future:wrap(fun(X) ->
                             X:get() + (Self ! 2)
                     end, F1),
    F3 = future:wrap(fun(Y) ->
                             Y:get() + (Self ! 3)
                     end, F2),
    ?assertEqual(6, F3:get()),
    timer:sleep(100),
    %% we should have exactly three messages in the queue
    ?assertEqual({messages, [1,2,3]}, process_info(self(), messages)),
    F3C = F3:clone(),
    ?assertEqual(6, F3C:get()),
    timer:sleep(100),
    %% we should have exactly six (three old + three new) messages in the queue
    ?assertEqual({messages, [1,2,3,1,2,3]}, process_info(self(), messages)),
    flush(),
    ok.

clone2_fun_test() ->
    Self = self(),
    F = future:new(fun() ->
                           Self ! 1,
                           43
                   end),
    F:get(),
    receive
        1 -> ok
    after 200 ->
            error(timeout)
    end,
    F2 = F:clone(),
    F3 = F2:realize(),
    receive
        1 -> ok
    after 200 ->
            error(timeout)
    end,
    ?assertEqual(43, F3:get()),
    flush().

clone_retry_test() ->
    Self = self(),
    F = future:new(fun() ->
                           Self ! 2,
                           error(test)
                   end),
    F2 = future:retry(F, 3),
    F3 = F2:realize(),
    receive 2 -> ok after 200 -> error(timeout) end,
    receive 2 -> ok after 200 -> error(timeout) end,
    receive 2 -> ok after 200 -> error(timeout) end,
    ?assertException(error, {retry_limit_reached, 3, _}, F3:get()),
    flush().

cancel_test() ->
    Self = self(),
    F = future:new(fun() ->
                           timer:sleep(100),
                           exit(Self, kill),
                           42
                   end),
    F:cancel(),
    timer:sleep(300),
    true.

safe_ok_test() ->
    F = future:new(fun() -> 1 end),
    F2 = future:safe(F),
    F3 = F2:realize(),
    ?assertEqual({ok, 1}, F3:get()).

safe_err_test() ->
    F = future:new(fun() -> error(1) end),
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

combine_test() ->
    T = ets:new(collect_test, [public]),
    ets:insert(T, {counter, 0}),
    Fun = fun() ->
                  ets:update_counter(T, counter, 1)
          end,
    F = future:combine([future:new(Fun),
                        future:new(Fun),
                        future:new(Fun)]),
    Res = F:get(),
    ?assertEqual([1,2,3], lists:sort(Res)).

select_static_errors_test() ->
    F = future:select_full([F1 = future:new(),
                            F2 = future:new()]),
    F1:set_error(badarg),
    F2:set_error(badarg),
    ?assertException(error,
                     all_futures_failed,
                     F:get()).

select_static_both_test() ->
    F = future:select_full([F1 = future:new(),
                            F2 = future:new()]),
    F1:set(1),
    F2:set_error(badarg),
    SR = F:get(),
    ?assertMatch({_, [_], []}, SR).

select_static_slow_test() ->
    F = future:select_full([ F1 = future:new(),
                             _F2 = future:new()]),
    F1:set(1),
    SR = F:get(),
    ?assertMatch({_, [], [_]}, SR).

select_mixed_test() ->
    T = ets:new(select_test, [public]),
    ets:insert(T, {counter, 0}),
    Fun = fun() ->
                  I = ets:update_counter(T, counter, 1),
                  timer:sleep(I * 100),
                  I
          end,
    SR = future:select_full([future:new_static_error(badarg),
                             future:new(Fun),
                             future:new(Fun),
                             future:new(Fun)]),
    ?assertMatch({_, [_], [_, _]}, SR:get()),
    {F, Errors, _Slow} = SR:get(),
    ?assertEqual(1, F:get()),
    [E] = Errors,
    ?assertException(error, badarg, E:get()).

select_all_fail_test() ->
    Fun = fun() ->
                  error(lets_fail)
          end,
    F = future:select_full([future:new(Fun),
                            future:new(Fun),
                            future:new(Fun)]),
    ?assertException(error,
                     all_futures_failed,
                     F:get()).

select_all_down_test() ->
    Fun = fun() ->
                  exit(self(), kill)
          end,
    All = [future:new(Fun),
           future:new(Fun),
           future:new(Fun)],
    F = future:select(All),
    ?assertException(error,
                     all_futures_failed,
                     F:get()).

wait_for_test() ->
    Pid = spawn(fun() -> timer:sleep(100) end),
    F = future:wait_for(Pid),
    ?assertMatch(normal, F:get()).

wait_for_fail_test() ->
    Pid = spawn(fun() -> timer:sleep(100), erlang:exit(badarg) end),
    F = future:wait_for(Pid),
    ?assertMatch(badarg, F:get()).

on_success_test() ->
    Self = self(),
    F = future:new_static(1),
    F:on_success(fun(X) ->
                         Self ! {done, X}
                 end),
    receive
        {done, X} ->
            ?assertEqual(1, X)
    after
        200 ->
            error(timeout)
    end.

on_done_value_test() ->
    Self = self(),
    F = future:new_static(777),
    F:on_done(fun(X) ->
                      Self ! {done, X}
              end),
    receive
        {done, X} ->
            ?assertEqual({ok, 777}, X)
    after
        200 ->
            error(timeout)
    end.

on_done_error_test() ->
    Self = self(),
    F = future:new_static_error(throw, interrupt),
    F:on_done(fun(X) ->
                      Self ! {done, X}
              end),
    receive
        {done, X} ->
            ?assertEqual({error, throw, interrupt}, X)
    after
        200 ->
            error(timeout)
    end.

on_success_wait_for_test() ->
    Self = self(),
    Pid = spawn(fun() -> timer:sleep(100) end),
    F = future:wait_for(Pid),
    F:on_success(fun(X) ->
                         Self ! {dead, X}
                 end),
    receive
        {dead, X} ->
            ?assertEqual(normal, X)
    after
        300 ->
            error(timeout)
    end.

flush() ->
    receive
        _ -> flush()
    after 0 ->
            ok
    end.
