# Erlfu #

Futures implemented in Erlang. Very basic implementation using
processes to represent a future.

Futures are actually [garbage collected processes](http://github.com/gleber/gcproc)
which are based on Tony Rogvall's [resource](http://github.com/tonyrog/resource) project.

Notes on limitations:

1. requires SMP support
2. garbage collection works only locally

## Goals ##

Implement futures/promises framework which allows to chain futures to
implement reusable mechanisms like timeouts, authentication, sharding,
etc.

Inspired by http://monkey.org/~marius/talks/twittersystems/

## Roadmap ##

- add wait_for/1 to wait for death of a process
- make set/2 and exec/2 transparent in regard to wrappers
- add on_success/1 and on_failure/1
- add wrappers that pass params to other futures for sharding and authentication
- add complex composition to
  - wait for all
  - wait for one
  - wait for specific, but gather other values

## Compositions ##

Currently the code supports three basic compositions:

1. timeout
2. retry
3. safe
4. catcher

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
Please note that currently futures are cloned shallowly.

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

Note: retry wrapper does work only on shallow futures, since cloning
is still shallow.

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
