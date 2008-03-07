-module(testlogrw).

-export([test/0]).

-define(PATH, "__test_file__").
-define(DATA, <<"Hello, world!!">>).

do_write(Fd, Pid) ->
	[logw:blog(Fd, ?DATA) || _ <- lists:seq(1, 500)],
	ok = logw:btrunc(Fd),
	Pid ! {truncate, self()},
	receive
		ok -> ok
	end,
	io:format("Ok~n"),
	ok.
	
test_write(Pid) ->
	{ok, Fd} = logw:open(?PATH),
	io:format("test_write - logw:open ok~n"),
	[do_write(Fd, Pid) ||  _ <- lists:seq(1, 100)],
	logw:close(Fd),
	Pid ! done,
	ok.
	
test_read() ->
	{ok, Fd} = logr:open(?PATH, "__testclient__", true),
	io:format("test_read - logr:open ok~n"),
	do_read(Fd),
	logr:close(Fd).
	
do_read(Fd) ->
	case logr:bget(Fd, 1) of
		{ok, [Data], _} ->
			io:format("~p~n", [Data]),
			?DATA = Data,
			do_read(Fd);
		eof ->
			receive
				{truncate, Pid} -> 
					io:format("Truncated~n"),
					logr:reset(Fd),
					Pid ! ok,
					do_read(Fd);
				done ->
					ok
			after 10 ->
				erlang:yield(),
				do_read(Fd)
			end
	end.

test() ->
	Pid = spawn(fun test_read/0),
	test_write(Pid),
	os:cmd("rm -rf " ++ ?PATH).

