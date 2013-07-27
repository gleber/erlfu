# Erlfu #

Futures implemented in Erlang. It's an implementation using processes
to represent a future. These futures can be used to:
1. Store a value later on
2. Compute a value using a fun
3. Chain/wrap futures to archive feature composition

Futures are actually [garbage collected processes](http://github.com/gleber/gcproc)
which are based on Tony Rogvall's [resource](http://github.com/tonyrog/resource) project.

Notes on limitations:

1. requires SMP support
2. garbage collection works only locally (i.e. future which is not
referenced on the node where it was created will be garbage collected)

## Goals ##

Implement futures/promises framework which allows to chain futures to
implement **reusable mechanisms** like timeouts, authentication, sharding,
etc.

Inspired by http://monkey.org/~marius/talks/twittersystems/

TODO: write more about futures, terminology and possible uses

## Roadmap ##

- make set/2 and exec/2 transparent in regard to wrappers ??
- add wrappers that pass params to other futures for sharding and authentication
- add complex composition to
-- wait for specific, but gather other values
-- retry next future if first is slow (i.e. redundant fetching data from
   replicated database if one of shards is slow)

## Compositions ##

Currently the code supports few basic compositions:

1. combine
2. select
3. timeout
4. retry
5. safe
6. catcher

## Examples ##

Simple example with delayed setting of value:
```erlang
1> F = future:new(fun() -> timer:sleep(10000), 10 end).
{future,<0.36.0>,#Ref<0.0.0.1736>,undefined}
2> F:get(). %% it hangs for 10 seconds
10
```

Exceptions are propagated with stacktrace preserved:
```erlang
4> F = future:new(fun() -> a = b end).
{future,<0.41.0>,#Ref<0.0.0.21416>,undefined}
5> F:get().
** exception error: no match of right hand side value b
     in function  erl_eval:expr/3
     in call from future:get/1 (src/future.erl, line 94)
6>
```

Values can be bound to future after it is created:
```erlang
7> F = future:new().
{future,<0.47.0>,#Ref<0.0.0.27235>,undefined}
8> spawn(fun() -> timer:sleep(10000), F:set(42) end).
<0.49.0>
9> F:get().
42
```

Futures can be cloned to rerun them if need be:
```erlang
65> F = future:new(fun() -> timer:sleep(5000), io:format("Run!~n"), crypto:rand_uniform(0, 100) end).
{future,{gcproc,<0.1546.0>,{resource,160354072,<<>>}},
        #Ref<0.0.0.2024>,undefined}
66> F:get().
Run!
16
67> F2 = F:clone().
{future,{gcproc,<0.1550.0>,{resource,160354272,<<>>}},
        #Ref<0.0.0.2033>,undefined}
68> F2:get().
Run!
75
```
Deeply wrapped futures can be cloned as well, see `future_tests:clone_side_effect_fun_test/0`.
Combined futures can be cloned as well, see `future_tests:clone_combined_test/0`.

Multiple futures' values can be collected. If one future fails
everything will fail:
```erlang
5> F1 = future:new(fun() -> timer:sleep(3000), 10 end).
{future,<0.50.0>,#Ref<0.0.0.76697>,undefined}
6> F2 = future:new(fun() -> timer:sleep(3000), 5 end).
{future,<0.53.0>,#Ref<0.0.0.76941>,undefined}
7> lists:sum(future:collect([F1, F2])).
15
```

One can map over futures, which allows to run multiple concurrent
computations in parallel:
```erlang
1> F1 = future:new(fun() -> timer:sleep(3000), 10 end).
{future,{gcproc,<0.45.0>,{resource,35806032,<<>>}},
        #Ref<0.0.0.86>,undefined}
2> F2 = future:new(fun() -> timer:sleep(3000), 5 end).
{future,{gcproc,<0.49.0>,{resource,35805216,<<>>}},
        #Ref<0.0.0.92>,undefined}
3> F3 = future:map(fun(X) -> X:get() * 2 end, [F1, F2]).
{future,{gcproc,<0.52.0>,{resource,35798200,<<>>}},
        #Ref<0.0.0.97>,undefined}
4> F3:get().
[20,10]
```

Futures can be used to capture process termination reason:
```erlang
1> Pid = spawn(fun() -> timer:sleep(10000), erlang:exit(shutdown) end).
<0.70.0>
2> F = future:wait_for(Pid).                    
{future,{gcproc,<0.72.0>,{resource,47420068511440,<<>>}},
        #Ref<0.0.0.276>,undefined}
3> F:get().
shutdown
```

A fun can be executed when future is bound:
```erlang
1> Self = self().
<0.38.0>
2> F = future:new(fun() -> timer:sleep(1000), 42 end).
{future,{gcproc,<0.46.0>,{resource,17793680,<<>>}},
        #Ref<0.0.0.104>,undefined}
3> F:on_done(fun(Result) -> Self ! Result end).
{future,{gcproc,<0.51.0>,{resource,47235452025976,<<>>}},
        #Ref<0.0.0.111>,undefined}
4> flush().
Shell got {ok,42}
ok
```
`future:on_success/2` and `future:on_failure/2` can be used to execute
a fun when future bounds to a value or to an exception respectively.

### Compositions ###

#### Timeout ####

Timeout future wrapper can be used to limit time of execution of a future:
```erlang
8> F = future:timeout(future:new(fun() -> timer:sleep(1000), io:format("Done!") end), 500).
{future,<0.51.0>,#Ref<0.0.0.18500>,undefined}
9> F:get().
** exception throw: timeout
     in function  future:'-timeout/2-fun-0-'/2 (src/future.erl, line 270)
     in call from future:'-wrap/2-fun-0-'/2 (src/future.erl, line 220)
     in call from future:'-do_exec/3-fun-0-'/3 (src/future.erl, line 42)
     in call from future:handle/1 (src/future.erl, line 188)
```
but if timeout time is larger than 1 second it will normally perform
expected computation:
```erlang
13> F = future:timeout(future:new(fun() -> timer:sleep(1000), io:format("Done!~n"), done_returned end), 5000), F:get().
Done!
done_returned
```

#### Retry ####
A wrapper which implements retrying in non-invasive way. It can be
used to limit number of retries of establishing connection to external
possibly-faulty resource. Example:

```erlang
10> F = future:new(fun() -> {ok, S} = gen_tcp:connect("faulty-host.com", 80, []), S end).
{future,<0.69.0>,#Ref<0.0.0.125>,undefined}
11> F2 = future:retry(F).
{future,<0.72.0>,#Ref<0.0.0.132>,undefined}
12> F2:get().
#Port<0.937>
```
or
```erlang
1> F = future:new(fun() -> {ok, S} = gen_tcp:connect("non-existing-host.com", 23, []), S end).
{future,<0.34.0>,#Ref<0.0.0.67>,undefined}
2> F2 = future:retry(F).
{future,<0.39.0>,#Ref<0.0.0.76>,undefined}
3> F2:get().
** exception error: {retry_limit_reached,3,{error,{badmatch,{error,nxdomain}}}}
     in function  erl_eval:expr/3
     in call from future:reraise/1 (src/future.erl, line 232)
     in call from future:'-wrap/2-fun-0-'/2 (src/future.erl, line 263)
     in call from future:'-do_exec/3-fun-0-'/3 (src/future.erl, line 43)
     in call from future:reraise/1 (src/future.erl, line 232)
```

#### Safe ####
Safe wrapper wraps future execution and catches errors and exits:
```erlang
18> F = future:safe(future:new(fun() -> error(error_in_computation) end)), F:get().
{error,error_in_computation}
```
but it will pass through throws, since they are a code flow control
tools.

#### Catcher ####
Catcher wrapper is a stronger variant of Safe wrapper, which
intercept all exceptions, including errors, exits and throws:
```erlang
21> F = future:catcher(future:new(fun() -> throw(premature_end) end)), F:get().
{error,throw,premature_end}
```
