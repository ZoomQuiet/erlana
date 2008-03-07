%% ------------------------------------------------------------------------------
%% Configuration

-define(READ_AHEAD_SIZE, 65536).

-define(LOGDATA_BASE_PATH,
	case os:getenv("LogDataBasePath") of
		false -> ".";
		LogDataBasePath -> LogDataBasePath
	end).

%% ------------------------------------------------------------------------------
%% IndexFile on disk

%%
%% fileFormat => indexHead indexRecord*
%% indexHead => IndexFileHeadTag:dword Version:dword
%% indexRecord => IndexFileTag:dword FileNo:dword Size:qword
%%

-define(IndexFileHeadTag, 3978514934). %% 0xED2351F6
-define(IndexHeadSize, 8).
-define(IndexFilePath(Path), filename:join(Path, "log.idx")).
-define(IndexFileTag, 3978514933). %% 0xED2351F5
-define(IndexWriteMode, [read, write, raw, binary]).
-define(IndexReadMode, [read, raw, binary]).
-define(IndexRecordSize, 16).
-define(IndexRecord(FileNo, Size), <<?IndexFileTag:32, FileNo:32, Size:64>>).

%% ------------------------------------------------------------------------------
%% PosFile on disk

%%
%% fileFormat => PosFileTag:dword FileNo:dword Offset:qword Version:dword
%%

-define(PosFilePath(Path, Client), filename:join(Path, Client ++ ".pos")).
-define(PosFileTag, 3978514931). %% 0xED2351F3
-define(PosReadWriteMode, [read, write, raw, binary]).
-define(PosFileSize, 20).

%% ------------------------------------------------------------------------------
%% SubLogFile on disk

%%
%% fileFormat => logRecord*
%% logRecord => RecordTag:dword Size:dword Data:byte[Size]
%%

-define(SubLogPath(Path, Num), filename:join(Path, "log." ++ integer_to_list(Num))).
-define(SubLogWriteMode, [read, write, raw, binary]).
-define(SubLogReadMode, [read, raw, binary, {read_ahead, ?READ_AHEAD_SIZE}]).
-define(RecordTag, 3978514932). %% 0xED2351F4
-define(RecordHeadSize, 8). %% 8 Bytes
-define(MakeRecord(Size, Bin), <<?RecordTag:32, (Size):32, (Bin)/binary>>).

%% ------------------------------------------------------------------------------
%% Helper macro

-define(MSG(Fmt, Args), io:format("========> INFO: " ++ Fmt, Args)).

-define(MSG0(Msg), ?MSG(Msg, [])).
-define(MSG1(Fmt, Arg), ?MSG(Fmt, [Arg])).
-define(MSG2(Fmt, Arg1, Arg2), ?MSG(Fmt, [Arg1, Arg2])).
-define(MSG3(Fmt, Arg1, Arg2, Arg3), ?MSG(Fmt, [Arg1, Arg2, Arg3])).
-define(MSG4(Fmt, Arg1, Arg2, Arg3, Arg4), ?MSG(Fmt, [Arg1, Arg2, Arg3, Arg4])).

%% ------------------------------------------------------------------------------
%% SUBLOG_MAX_BYTES: Configuration of a single logfile.

-define(GBYTES, 1073741824). %% 1G
-define(GBYTES_X2, 2147483648). %% 2G
-define(GBYTES_X0_5, 536870912). %% 0.5G
-define(GBYTES_X1_5, 1610612736). %% 1.5G
-define(GBYTES_X10, 10737418240). %% 10G
-define(SUBLOG_MAX_BYTES, ?GBYTES_X1_5).

%% ------------------------------------------------------------------------------
%% LogServer name

-define(LogWServer(Path), list_to_atom("dc.log:" ++ Path)).
-define(LogRServer(Path, Client), list_to_atom(lists:flatten(["dc.log:", Path, ":", Client]))).
-define(IsRunning(ServName), lists:member(ServName, registered())).

-define(SELF, element(2, erlang:process_info(self(), registered_name))). %% Atom

%% ------------------------------------------------------------------------------

