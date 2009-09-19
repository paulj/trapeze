-module(trapeze).
-author('Paul Jones <paulj@lshift.net>').
-export([start/0, stop/0]).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.
        
%% @spec start() -> ok
%% @doc Start the trapeze server.
start() ->
    ensure_started(rabbit_mochiweb),
    application:start(trapeze).

%% @spec stop() -> ok
%% @doc Stop the trapeze server.
stop() ->
    application:stop(trapeze).