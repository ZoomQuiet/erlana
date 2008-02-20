-module(logr).
-behaviour(gen_server).
-include("log.hrl").
-include_lib("kernel/include/file.hrl").

%% export functions
-export([open/2, open/3, bchunk/2, bget/2, bcount/1, btell/1, blist/1, position/2, reset/1, close/1]).
-export([get/3, tell/2, reset/2, close/2]).
-export([i/1, repair/3, repairIndex/1]).

%% required by 'gen_server' behaviour
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-record(position, {fileNo, offset}).
-record(state,
{
	fd,			%% file_description - Current SubLog File Description
	fileNo,		%% int - File Number of Current SubLog
	offset,		%% int64 - Read Position of Current SubLog
	cbSize,		%% int64 - File Size of Current SubLog

	indexTable,	%% tuple of int64 - Index Table.
	version,	%% int - Version of LogFile

	path,		%% string - Path of LogFile
	logW,		%% atom - Registered Name of logw server
	fdPos		%% file_description - PosFile File Description
}).

%% ------------------------------------------------------------------------------
%% export functions

%%
%% open: Open log file.
%% return: {ok, Log} | {error, Reason}
%%
open(Path, Client) ->
	open(Path, Client, false).
		
%% FPermanent = true | false
open(Path, Client, FPermanent) ->
	Log = ?LogRServer(Path, Client),
	case catch (gen_server:start_link(
    	_ServName = {local, Log},
    	_ModCallback = ?MODULE,	_Arg = {Path, Client, FPermanent}, _Options = [])
    ) of
		{ok, _Pid} ->
			{ok, Log};
		{error, {already_started, _Pid}} ->
			{ok, Log};
		Fail ->
			{error, Fail}
	end.

%%
%% bchunk: Read log data
%% return: {ok, Acc, FromWhere} | {need_repair, {FileNo, Offset}}
%%	eof = (length(Acc) == 0)
%%	Bins = lists:reverse(Acc)
%%
bchunk(Log, N) ->
	gen_server:call(Log, {bchunk, N}).

%%
%% bget: Read log data
%% return: {ok, Bins} | {need_repair, {FileNo, Offset}}
%%
bget(Log, N) ->
	case bchunk(Log, N) of
		{ok, Acc, _FromWhere} ->
			{ok, lists:reverse(Acc)};
		Fail ->
			Fail
	end.

%%
%% get: Read log data
%% return: {ok, Bins} | {need_repair, {FileNo, Offset}}
%%
get(Path, Client, N) ->
	Log = ?LogRServer(Path, Client),
	case catch (bchunk(Log, N)) of
		{ok, Acc, _FromWhere} ->
			{ok, lists:reverse(Acc)};
		_Fail ->
			{ok, _Log} = open(Path, Client, true),
			catch (bget(Log, N))
	end.

%%
%% count: Count of a log file.
%% return: {ok, Count} | {error, OkCount, Reason}
%%
bcount(Log) ->
	case bchunk(Log, -1) of
		{ok, Bins, _FromWhere} ->
			{ok, length(Bins)};
		_Fail ->
			{ok, 0}
	end.

%%
%% list: List a log file.
%% return: <LogHistory> = [binary()]
%%
blist(Log) ->
	case bget(Log, -1) of
		{ok, Bins} ->
			Bins;
		_Fail ->
			[]
	end.

%%
%% position: Seek to new position.
%% return: ok | {error, Reason}
%%
position(Log, Position) ->
	gen_server:call(Log, {position, Position}).

reset(Log) ->
	gen_server:call(Log, {position, #position{fileNo=1, offset=0}}).

reset(Path, Client) ->
	Log = ?LogRServer(Path, Client),
	Position = #position{fileNo=1, offset=0},
	case catch (position(Log, Position)) of
		ok -> ok;
		_Fail ->
			{ok, _Log} = open(Path, Client, true),
			catch (position(Log, Position))
	end.

%%
%% tell: Tell current position.
%% return: {ok, Position} | {error, Reason}
%%
btell(Log) ->
	gen_server:call(Log, tell).

tell(Path, Client) ->
	Log = ?LogRServer(Path, Client),
	case catch (btell(Log)) of
		{ok, Position} ->
			{ok, Position};
		_Fail ->
			{ok, _Log} = open(Path, Client, true),
			catch (btell(Log))
	end.

%%
%% i: Information of a log file.
%% return: ok
%%
i(Log) ->
	gen_server:call(Log, i).

%%
%% open: Close log file.
%% return: ok | {error, Reason}
%%
close(Log) ->
	gen_server:call(Log, close).

close(Path, Client) ->
	Log = ?LogRServer(Path, Client),
	{gen_server:call(Log, close), Log}.

%% ------------------------------------------------------------------------------
%% utilities

%%
%% repair: Repair a sublog file.
%% return: ok | {error, Reason}
%%
repair(Path, FileNo, Offset) ->
	{ok, LogWServer} = logw:open(Path, ?SUBLOG_MAX_BYTES),
	Ret = logw:repair(LogWServer, FileNo, Offset),
	logw:close(LogWServer),
	Ret.

%%
%% repairIndex: Repair a log file index.
%% return: ok | {error, Reason}
%%
repairIndex(Path) ->
	{ok, LogWServer} = logw:open(Path, ?SUBLOG_MAX_BYTES),
	logw:close(LogWServer),
	ok.

%% ------------------------------------------------------------------------------
%% callback functions

%%
%% readIndex: read index file.
%% return: {ok, IndexTable, Version} | {error, Reason} | !exception {need_repair_index}
%%	 IndexTable = {Size..}
%%
readIndex(Path) ->
	IndexFile = ?IndexFilePath(Path),
	case file:read_file(IndexFile) of
		{ok, <<?IndexFileHeadTag:32, Version:32, Binary/binary>>} ->
			{ok, Acc} = readIndex(Path, Binary, 1, []),
			IndexTable = erlang:list_to_tuple(lists:reverse(Acc)),
			{ok, IndexTable, Version};
		{error, Reason} ->
			{error, Reason}
	end.

readIndex(Path, <<?IndexFileTag:32, FileNo:32, Size:64, RestBin/binary>>, FileNo, Acc) ->
	readIndex(Path, RestBin, FileNo+1, [Size | Acc]);
readIndex(_Path, <<>>, _FileNo, Acc) ->
	{ok, Acc}.

%%
%% update: Update state.
%% return: no_update | {update, State} | {need_repair, {FileNo, Offset}}
%%
update(FileNo, OldSize, State) ->
	%% ?MSG("Update ~p: fileNo=~p, fileSize=~p~n", [State#state.path, FileNo, OldSize]),
	case catch (logw:sync(State#state.logW, false)) of
		{ok, {FileNoCur, FileSizeCur, NewVersion}} ->
			%% ?MSG("Sync ~p: fileNoCur=~p, fileSize=~p, version=~p~n", [State#state.path, FileNoCur, FileSizeCur, NewVersion]),
			if State#state.version =:= NewVersion ->
				if FileNoCur =:= FileNo ->
					if
						FileSizeCur =:= OldSize -> %% no more data, and no next sublog file.
							no_update;
						true -> %% has new log data
							IndexTable = setelement(FileNo, State#state.indexTable, FileSizeCur),
							{update, State#state{cbSize=FileSizeCur, indexTable=IndexTable}}
					end;
				true ->
					{ok, IndexTable2, Version2} = readIndex(State#state.path),
					State2 = State#state{indexTable = IndexTable2, version=Version2},
					case element(FileNo, IndexTable2) of
						OldSize -> %% no more data, but have next sublog file.
							case positionNew(FileNo+1, 0, State2) of
								{reply, ok, State3} ->
									{update, State3};
								_Fail ->
									{need_repair, {FileNo+1, 0}}
							end;
						NewSize ->
							{update, State2#state{cbSize=NewSize}}
					end
				end;
			true -> %% trunc
				?MSG0("Truncated.~n"),
				file:close(State#state.fd),
				{ok, IndexTable2, Version2} = readIndex(State#state.path),
				State2 = State#state{fd=0, fileNo=0, offset=0, cbSize=0, indexTable=IndexTable2, version=Version2},
				{update, State2}
			end;
		_NotStarted ->
			no_update
	end.
	
%%
%% savePosition
%%
savePosition(State) ->
	case State#state.fdPos of
		undefined ->
			ok;
		FdPos ->
			#state{fileNo=FileNo, offset=Offset} = State,
			?MSG("savePosition ~p: fileNo=~p, offset=~p~n", [State#state.path, FileNo, Offset]),
			ok = file:pwrite(FdPos, 0, <<?PosFileTag:32, FileNo:32, Offset:64>>)
	end.

%%
%% positionNew/positionTo: Seek to position
%% return {reply, ok, State} | {reply, {error, Reason}, State}
%%
positionNew(FileNo, Offset, State) ->
	Size = element(FileNo, State#state.indexTable),
	if
		Offset > Size ->
			{reply, {error, out_of_range}, State};
		true ->
			SubLogFile = ?SubLogPath(State#state.path, FileNo),
			case file:open(SubLogFile, ?SubLogReadMode) of
				{ok, FdSubLog} ->
					if Offset =:= 0 -> ok;
					   true -> {ok, Offset} = file:position(FdSubLog, Offset) end,
					if State#state.fd =:= 0 -> ok;
					   true -> file:close(State#state.fd) end,
					{reply, ok, State#state{fd=FdSubLog, fileNo=FileNo, offset=Offset, cbSize=Size}};
				Fail ->
					{reply, Fail, State}
			end
	end.

positionTo(NewPosition, State) ->
	#state{cbSize=Size, fileNo=FileNo} = State,
	#position{offset=NewOffset, fileNo=NewFileNo} = NewPosition,
	if
		NewFileNo =:= FileNo ->
			if
				NewOffset > Size ->
					{reply, {error, out_of_range}, State};
				true ->
					{ok, NewOffset} = file:position(State#state.fd, NewOffset),
					{reply, ok, State#state{offset=NewOffset}}
			end;
		true ->
			positionNew(NewFileNo, NewOffset, State)
	end.

%%
%% readSingle: Read log data in a sub log file.
%% return: {ok, RestSize, Acc} | {eof, RestN, Acc} | !exception{need_repair}
%%    Bins = lists:reverse(Acc)
%%
readSingle(_FdSubLog, RestSize, 0, Acc) ->
	{ok, RestSize, Acc};
readSingle(FdSubLog, RestSize, N, Acc) ->
	if
		?RecordHeadSize < RestSize ->
			case file:read(FdSubLog, ?RecordHeadSize) of
				{ok, <<?RecordTag:32, (Size):32>>} ->
					true = (?RecordHeadSize + Size =< RestSize),
					{ok, Bin} = file:read(FdSubLog, Size),
					Size = size(Bin),
					readSingle(FdSubLog, RestSize - (?RecordHeadSize + Size), N-1, [Bin | Acc]);
				eof ->
					{eof, N, Acc}
			end;
		true ->
			{eof, N, Acc}
	end.

%%
%% read: Read log data.
%% return: {ok, Acc, State2} | !exception {need_repair, {FileNo, Offset}}
%%	eof = (length(Acc) == 0)
%%	Bins = lists:reverse(Acc)
%%
read(N, Acc, State) ->
	#state{fd=FdSubLog, cbSize=Size, offset=Offset} = State,
	%% ?MSG("Read ~p: fileNo=~p, offset=~p, size=~p fileNoLast=~p~n", [State#state.path, FileNo, Offset, Size, size(State#state.indexTable)]),
	case catch(readSingle(FdSubLog, Size-Offset, N, Acc)) of
		{ok, RestSize, Acc2} ->
			{ok, Acc2, State#state{offset=Size-RestSize}};
		{eof, RestN, Acc2} ->
			FileNo = State#state.fileNo,
			if
				FileNo < size(State#state.indexTable) ->
					{reply, ok, State2} = positionNew(FileNo+1, 0, State),
					read(RestN, Acc2, State2);
				true ->
					State3 = State#state{offset=Size},
					case update(FileNo, Size, State3) of
						no_update ->
							{ok, Acc2, State3};
						{update, State4} ->
							read(RestN, Acc2, State4)
						%%NeedRepair ->
						%%	{reply, NeedRepair, State3}
					end
			end;
		_Fail ->
			ok = repair(State#state.path, State#state.fileNo, Offset),
			file:position(FdSubLog, Offset),
			read(N, Acc, State)
	end.

%%
%% init: Initialize log server & open a log file.
%%
init({Path, Client, FPermanent}) ->
	%% Read index from file:
	ok = repairIndex(Path),
	case catch (readIndex(Path)) of
		{ok, IndexTable, Version} ->
			?MSG("Init ~p: fileNoLast=~p version=~p~n", [Path, size(IndexTable), Version]),
			State0 = #state{fd=0, fileNo=0, offset=0, cbSize=0,
				path=Path, indexTable=IndexTable, version=Version, logW=?LogWServer(Path)},
			%% Read pos file:
			if FPermanent =:= true ->
				{ok, FdPos} = file:open(?PosFilePath(Path, Client), ?PosReadWriteMode),
				State1 = State0#state{fdPos=FdPos},
				case file:read(FdPos, ?PosFileSize) of
					{ok, <<?PosFileTag:32, FileNo:32, Offset:64>>} ->
						?MSG("loadPosition ~p: fileNo=~p, offset=~p~n", [Path, FileNo, Offset]),
						case positionNew(FileNo, Offset, State1) of
							{reply, ok, State2} ->
								{ok, State2};
							{reply, Fail, _State} ->
								{stop, Fail}
						end;
					_Eof ->
						{ok, State1}
				end;
			true ->
				{ok, State0}
			end;
		Fail ->
			{stop, {need_repair_index, Fail}}
	end.

%%
%% terminate: Termiate server.
%%
terminate(_Reason, State) ->
	case State#state.fdPos of
		undefined ->
			ok;
		FdPos ->
			file:close(FdPos)
	end.

%%
%% bchunk: Read log data.
%% return: {ok, Acc, FromWhere} | !exception {need_repair, {FileNo, Offset}}
%%	eof = (length(Acc) == 0)
%%	Bins = lists:reverse(Acc)
%%
handle_call({bchunk, N}, _From, State) ->
	#state{fileNo=FileNo, offset=Offset} = State,
	FromWhere = #position{fileNo=FileNo, offset=Offset},
	case read(N, [], State) of
		{ok, Acc2, State2} ->
			if Acc2 =:= [] -> ok;
			   true -> savePosition(State2) end,
			{reply, {ok, Acc2, FromWhere}, State2};
		Fail ->
			%% ?MSG("Bchunk ~p: ~p~n", [State#state.path, Fail]),
			{reply, Fail, State}
	end;

%%
%% tell: Tell current position.
%% return: {ok, Position} | {error, Reason}
%%
handle_call(tell, _From, State) ->
	#state{fileNo=FileNo, offset=Offset} = State,
	{reply, {ok, #position{fileNo=FileNo, offset=Offset}}, State};

%%
%% position: Seek to new position.
%% return: ok | {error, Reason}
%%
handle_call({position, NewPosition}, _From, State) ->
	Return = positionTo(NewPosition, State),
	if element(2, Return) =:= ok -> savePosition(State); true -> ok end,
	Return;

%%
%% i: Information of a log file.
%% return: {ok, [Info]} | {error, Reason}
%%
handle_call(i, _From, State) ->
	#state{fileNo=FileNo, offset=Offset, path=Path, indexTable=IndexTable, version=Version, fdPos=FdPos} = State,
	Info = [
		#position{offset=Offset, fileNo=FileNo},
		{index, IndexTable}, {path, Path}, {version, Version}, {permanent, FdPos =/= undefined}
		],
	{reply, {ok, Info}, State};

%%
%% close: Close a log file.
%% return: ok | {error, Reason}
%%
handle_call(close, _From, State) ->
	{stop, normal, ok, State}.

%%
%% stop: Stop log server.
%%
handle_cast(stop, State) ->
	{stop, normal, State}.

%%
%% handle_info
%%
handle_info(Info, State) ->
	io:format("Module: ~p~nUnknown info: ~p~n", [?MODULE, Info]),
    {noreply, State}.

%%
%% code_change({down,ToVsn}, State, Extra)
%% 
%% NOTE:
%% Actually upgrade from 2.5.1 to 2.5.3 and downgrade from 
%% 2.5.3 to 2.5.1 is done with an application restart, so 
%% these function is actually never used. The reason for keeping
%% this stuff is only for future use.
%%
code_change({down,_ToVsn}, State, _Extra) ->
    {ok,State};

%% code_change(FromVsn, State, Extra)
%%
code_change(_FromVsn, State, _Extra) ->
    {ok,State}.

