-module(future_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").


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

realize_test() ->
    F = future:new(),
    F:set(42),
    F2 = F:realize(),
    ?assertEqual(42, F2:get()).

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

%% clone_deep_fun_test() ->
%%     Fun1V = 1,
%%     Fun2V = 2,
%%     Fun3V = 3,
%%     F1 = future:new(fun() ->
%%                             term_to_binary(Fun1V),
%%                             Fun1V
%%                     end),
%%     %% ?assertEqual(1, F1:get()),
%%     %% F1C = F1:clone(),
%%     %% ?assertEqual(1, F1C:get()),
%%     F2 = future:wrap(fun(X) ->
%%                              term_to_binary(Fun2V),
%%                              X:get() + Fun2V
%%                      end, F1),
%%     %% ?assertEqual(3, F2:get()),
%%     F3 = future:wrap(fun(Y) ->
%%                              term_to_binary(Fun3V),
%%                              Y:get() + Fun3V
%%                      end, F2),
%%     %% ?assertEqual(6, F3:get()),
%%     F3C = F3:clone(),
%%     ?assertEqual(6, F3C:get()),
%%     ok.

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
    ?assertEqual(43, F3:get()).

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
    ?assertException(error, {retry_limit_reached, 3, _}, F3:get()).

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

collect_test() ->
    T = ets:new(collect_test, [public]),
    ets:insert(T, {counter, 0}),
    Fun = fun() ->
                  ets:update_counter(T, counter, 1)
          end,
    Res = future:collect([future:new(Fun),
                          future:new(Fun),
                          future:new(Fun)]),
    ?assertEqual([1,2,3], lists:sort(Res)).
