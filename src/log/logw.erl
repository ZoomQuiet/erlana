-module(logw).
-behaviour(gen_server).
-include("log.hrl").
-include_lib("kernel/include/file.hrl").

%% export functions
-export([open/1, open/2, blog/2, btrunc/1, sync/2, repair/3, close/1]).
-export([put/2, trunc/1, stop/1]).

%% required by 'gen_server' behaviour
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-record(state,
{
	fd,			%% file_description - Current SubLog File Description
	fdIdx,		%% file_description - LogIndexFile File Description
	path,		%% string - Path of Log File, with LogDataBasePath joined
	fileNo,		%% int - Current SubLog FileNo
	cbSize,		%% int64 - Current SubLog FileSize
	cbMaxSize,	%% int64 - SubLog Limited Size (MaxSize)
	version,	%% int - Version of Log File
	fDirty = false,	%% bool - Changed or not
	nRef = 1		%% int - Reference count of LogWServer
}).

%% ------------------------------------------------------------------------------
%% export functions

-compile({inline,{blog,2}}).

%%
%% open: Open log file.
%% return: {ok, Log} | {error, Reason}
%%
open(Path, MaxSize) ->
	PathWithBase = filename:join(?LOGDATA_BASE_PATH, Path),
	case filelib:ensure_dir(?IndexFilePath(PathWithBase)) of
		Return when Return =:= ok; Return =:= {error,eexist} ->
			Log = ?LogWServer(Path),
			case catch (gen_server:start_link(
				_ServName = {local, Log},
				_ModCallback = ?MODULE,	_Arg = {PathWithBase, MaxSize}, _Options = [])
			) of
				{ok, _Pid} ->
					{ok, Log};
				{error, {already_started, _Pid}} ->
					gen_server:call(Log, acquire),
					{ok, Log};
				Fail ->
					{error, Fail}
			end;
		Fail ->
			?MSG("logw: ensure_dir ~p failed: ~p~n", [PathWithBase, Fail]),
			Fail
	end.

open(Path) ->
	open(Path, ?SUBLOG_MAX_BYTES).

%%
%% trunc: empty a log file
%% return: ok | {error, Reason}
%%
btrunc(Log) ->
	gen_server:call(Log, trunc).
	
trunc(Path) when is_list(Path) ->
	Log = ?LogWServer(Path),
	case catch(gen_server:call(Log, trunc)) of
		ok ->
			ok;
		_Fail ->
			logw:open(Path, ?SUBLOG_MAX_BYTES),
			catch(gen_server:call(Log, trunc))
	end;
trunc(Log) ->
	gen_server:call(Log, trunc).

%%
%% blog: Write log data
%% return: ok | {error, Reason}
%%
blog(Log, Bin) ->
	gen_server:call(Log, {blog, Bin}).

put(Path, Bin) ->
	Log = ?LogWServer(Path),
	case catch(gen_server:call(Log, {blog, Bin})) of
		ok ->
			ok;
		_Fail ->
			logw:open(Path, ?SUBLOG_MAX_BYTES),
			catch(gen_server:call(Log, {blog, Bin}))
	end.

%%
%% sync: Update index, and write to disk (if FSyncIoDev is true)
%% return: {ok, {FileNoCur, FileSizeCur, Version}} | {error, Reason}
%%
sync(Log, FSyncIoDev) ->
	gen_server:call(Log, {sync, FSyncIoDev}).

%%
%% repair: Repair a sublog file from a start position.
%% return: ok | {error, Reason}
%%
repair(Log, FileNo, Offset) ->
	gen_server:call(Log, {repair, FileNo, Offset}).

%%
%% open: Close log file.
%% return: NRef | {error, Reason}
%%   NRef = 0 means close the log file indeed.
%%
close(Log) ->
	gen_server:call(Log, close).
	
stop(Path) ->
	Log = ?LogWServer(Path),
	gen_server:cast(Log, stop).

%% ------------------------------------------------------------------------------
%% callback functions

%%
%% readIndex: read index file.
%% return: {ok, {FdIdx, FileNo, Size, Version}} | {error, Reason} | !exception {need_repair_index}
%%
readIndex(IndexFile) ->
	case file:read_file(IndexFile) of
		{ok, <<?IndexFileHeadTag:32, Version:32, Binary/binary>>} ->
			FileNo = size(Binary) div ?IndexRecordSize,
			Offset = (FileNo-1) * ?IndexRecordSize,
			<<_:Offset/binary, ?IndexFileTag:32, FileNo:32, Size:64>> = Binary,
			{ok, FdIdx} = file:open(IndexFile, ?IndexWriteMode),
			{ok, {FdIdx, FileNo, Size, Version}};
		{error, enoent} -> %% The file does not exist.
			{ok, FdIdx} = file:open(IndexFile, ?IndexWriteMode),
			writeVersion(FdIdx, 1),
			{ok, {FdIdx, 1, 0, 1}};
		{error, Reason} ->
			{error, Reason}
	end.

%%
%% writeVersion: write log file version.
%% return: ok | {error, Reason}
%%
writeVersion(Fd, Version) ->
	file:position(Fd, 0),
	file:write(Fd, <<?IndexFileHeadTag:32, Version:32, ?IndexFileTag:32, 1:32, 0:64>>),
	file:truncate(Fd),
	file:sync(Fd).

%%
%% writeIndex: write index file.
%% return: ok | {error, Reason}
%%
writeIndex(Fd, FileNo, Size) ->
	file:pwrite(Fd, ?IndexHeadSize + ?IndexRecordSize * (FileNo-1), ?IndexRecord(FileNo, Size)).

%%
%% truncLog: Empty a log file
%% return: {reply, ok, NewState} | {reply, {error, Reason}, State}
%%
truncLog(State) ->
	file:position(State#state.fd, 0),
	State2 = truncSubLogFiles(State),
	#state{fdIdx=FdIdx, version=Version} = State2,
	writeVersion(FdIdx, Version+1),
	{reply, ok, State2#state{version=Version+1}}.

truncSubLogFiles(#state{fileNo=FileNo, fd=FdSubLog, path=Path} = State) ->
	ok = file:truncate(FdSubLog),
	if FileNo =:= 1 ->
		State#state{cbSize = 0};
	true ->
		file:close(FdSubLog),
		SubLogFile = ?SubLogPath(Path, FileNo-1),
		{ok, FdSubLog2} = file:open(SubLogFile, ?SubLogWriteMode),
		truncSubLogFiles(State#state{fd=FdSubLog2, fileNo=FileNo-1})
	end.

%%
%% validateSingle: Validate log data in a sub log file.
%% return: {ok, GoodDataSize}
%%
validateSingle(FdSubLog, Offset, FileSize) ->
	case file:read(FdSubLog, ?RecordHeadSize) of
		{ok, <<?RecordTag:32, Size:32>>} ->
			NewOffset = Offset + (?RecordHeadSize + Size),
			if
				NewOffset =< FileSize ->
					case file:read(FdSubLog, Size) of
						{ok, Bin} ->
							if
								Size =:= size(Bin) ->
									validateSingle(FdSubLog, NewOffset, FileSize);
								true ->
									{ok, Offset}
							end;
						_Fail ->
							{ok, Offset}
					end;
				true ->
					{ok, Offset}
			end;
		_Fail ->
			{ok, Offset}
	end.

%%
%% repairLog: Repair a sublog file.
%% return: {ok, GoodSize, FileSize} | {error, Reason}
%% return state: Current position is undefined.
%%
repairLog(Offset, State) ->
	#state{fd=FdSubLog, fdIdx=FdIdx, path=Path, fileNo=FileNo, cbSize = FileSize} = State,
	if
		Offset < FileSize ->
			{ok, Offset} = file:position(FdSubLog, Offset),
			{ok, GoodSize} = validateSingle(FdSubLog, Offset, FileSize),
			ok = writeIndex(FdIdx, FileNo, GoodSize),
			if GoodSize < FileSize ->
				?MSG("Repaired ~p: {goodSize=~p, fileSize=~p}~n", [?SubLogPath(Path, FileNo), GoodSize, FileSize]);
			true ->
				?MSG0("Repaired, no bad bytes.~n")
			end,
			{ok, GoodSize, FileSize};
		true ->
			{ok, FileSize, FileSize}
	end.

%%
%% init: Initialize log server & open a log file.
%%
init({Path, MaxSize}) ->
	%% Read index from file:
	IndexFile = ?IndexFilePath(Path),
	case readIndex(IndexFile) of
		{ok, {FdIdx, FileNo, Size, Version}} ->
			%% Open sublog file:
			SubLogFile = ?SubLogPath(Path, FileNo),
			case file:open(SubLogFile, ?SubLogWriteMode) of
				{ok, FdSubLog} ->
					{ok, FileSize} = file:position(FdSubLog, eof),
					State = #state{fd=FdSubLog, fdIdx=FdIdx, path=Path, 
						fileNo=FileNo, cbSize=FileSize, cbMaxSize=MaxSize, version=Version},
					if
						FileSize =:= Size ->
							{ok, State};
						true ->
							{ok, GoodSize, _} = repairLog(Size, State),
							{ok, GoodSize} = file:position(FdSubLog, GoodSize),
							State2 = State#state{cbSize = GoodSize},
							{ok, State2}
					end;
				Fail ->
					{stop, Fail}
			end;
		Fail ->
			{stop, Fail}
	end.

%%
%% terminate: Termiate server.
%%
terminate(_Reason, State) ->
	#state{fd=FdSubLog, fdIdx=FdIdx, fileNo=FileNo, cbSize=Size} = State,
	file:close(FdSubLog),
	ok = writeIndex(FdIdx, FileNo, Size),
	file:close(FdIdx),
	ok.

%%
%% blog: Write log data.
%% return: ok | {error, Reason}
%%
handle_call({blog, Bin}, _From, State) ->
	#state{fd=FdSubLog, fdIdx=FdIdx, path=Path, fileNo=FileNo, cbSize = OldSize, cbMaxSize=MaxSize} = State,
	Size = size(Bin),
	case file:write(FdSubLog, ?MakeRecord(Size, Bin)) of
		ok ->
			NewSize = OldSize + Size + ?RecordHeadSize,
			if
				NewSize < MaxSize ->
					{reply, ok, State#state{cbSize=NewSize, fDirty=true}};
				true ->
					file:close(FdSubLog),
					ok = writeIndex(FdIdx, FileNo, NewSize),
					ok = writeIndex(FdIdx, FileNo+1, 0),
					SubLogFile2 = ?SubLogPath(Path, FileNo+1),
					{ok, FdSubLog2} = file:open(SubLogFile2, ?SubLogWriteMode), %% crash when disk full.
					{reply, ok, State#state{fd=FdSubLog2, fileNo=FileNo+1, cbSize=0}}
			end;
		Fail ->
			{reply, Fail, State}
	end;

%%
%% sync: Update index, and write to disk (if FSyncIoDev is true)
%% return: {ok, {FileNoCur, FileSizeCur, Version}} | {error, Reason}
%%
handle_call({sync, FSyncIoDev}, _From, State) ->
	#state{fileNo=FileNo, cbSize=Size, version=Version, fDirty=FDirty} = State,
	case FDirty of
		true ->
			ok = writeIndex(State#state.fdIdx, FileNo, Size),
			State2 = State#state{fDirty=false};
		_False ->
			State2 = State
	end,
	{
		reply,
		{
			case FSyncIoDev of
				true ->
					file:sync(State#state.fd),
					file:sync(State#state.fdIdx),
					ok;
				_False2 ->
					ok
			end,
			{FileNo, Size, Version}
		},
		State2
	};

%%
%% acquire: Acquire a log file.
%% return: ok | {error, Reason}
%%
handle_call(acquire, _From, State) ->
	NRef = State#state.nRef,
	{reply, ok, State#state{nRef=NRef+1}};

%%
%% repair: Repair a sublog file.
%% return: ok | {error, Reason}
%%
handle_call({repair, FileNo, Offset}, _From, State) ->
	SubLogFile = ?SubLogPath(State#state.path, FileNo),
	case file:read_file_info(SubLogFile) of
		{ok, #file_info{size=FileSize}} ->
			case file:open(SubLogFile, ?SubLogWriteMode) of
				{ok, FdSubLog} ->
					State2 = State#state{fd=FdSubLog, fileNo=FileNo, cbSize=FileSize},
					Ret = repairLog(Offset, State2),
					file:close(FdSubLog),
					{reply, Ret, State};
				Fail ->
					{reply, Fail, State}
			end;
		Fail ->
			{reply, Fail, State}
	end;

%%
%% trunc: Empty a log file.
%% return: ok | {error, Reason}
%%
handle_call(trunc, _From, State) ->
	truncLog(State);

%%
%% close: Close a log file.
%% return: NRef | {error, Reason}
%%
handle_call(close, _From, State) ->
	NRef = State#state.nRef - 1,
	if
		NRef =:= 0 ->
			{stop, normal, 0, State};
		true ->
			{reply, NRef, State#state{nRef=NRef}}
	end.

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

