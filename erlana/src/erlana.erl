%% @author author <author@example.com>
%% @copyright YYYY author.

%% @doc TEMPLATE.

-module(erlana).
-author('author <author@example.com>').
-export([start/0, stop/0]).

ensure_started(App) ->
    case application:start(App) of
	ok ->
	    ok;
	{error, {already_started, App}} ->
	    ok
    end.
	
%% @spec start() -> ok
%% @doc Start the erlana server.
start() ->
    erlana_deps:ensure(),
    ensure_started(crypto),
    application:start(erlana).

%% @spec stop() -> ok
%% @doc Stop the erlana server.
stop() ->
    Res = application:stop(erlana),
    application:stop(crypto),
    Res.
