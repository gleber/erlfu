-module(erlfu).

-export([start/0]).

ensure_started(App) ->
    case application:start(App) of
        ok -> ok;
        {error, {already_started, App}} ->
            ok
    end.

start() ->
    ensure_started(gcproc),
    ensure_started(erlfu).
