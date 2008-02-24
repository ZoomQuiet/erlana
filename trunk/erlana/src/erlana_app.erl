%% @author author <author@example.com>
%% @copyright YYYY author.

%% @doc Callbacks for the erlana application.

-module(erlana_app).
-author('author <author@example.com>').

-behaviour(application).
-export([start/2,stop/1]).


%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for erlana.
start(_Type, _StartArgs) ->
    erlana_deps:ensure(),
    erlana_sup:start_link().

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for erlana.
stop(_State) ->
    ok.
