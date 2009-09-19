%% @doc Callbacks for the trapeze application.

-module(trapeze_app).
-author('Paul Jones <paulj@lshift.net>').

-behaviour(application).
-export([start/2,stop/1]).


%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for trapeze.
start(_Type, _StartArgs) ->
    Res = trapeze_sup:start_link(),
    rabbit_mochiweb:register_global_handler(fun(Req) -> trapeze_web:handle_request(Req) end),
    Res.

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for trapeze.
stop(_State) ->
    ok.
