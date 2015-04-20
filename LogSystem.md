# Why not disk\_log? #

I use disk\_log some time ago. But I found that I have no control of the disk file format. So I decided to write a log system by myself. For more information, refer [issue #5](https://code.google.com/p/erlana/issues/detail?id=#5).

# Write log #

Erlana log system is easy to use. Here is an example code:
```
logw:put("Logfile", <<"Test1">>),
logw:put("Logfile", <<"Test2">>).
```

It will create a log file named "Logfile" (Logically. In fact, a directory named "Logfile" will be created). And write two log entries (<<"Test1">> and <<"Test2">>) to the log file.

Erlana log system only support to write binary data. If you want to write any erlang term, use term\_to\_binary/1.

If you want to clear all data of a log file, just like this:
```
logw:trunc("Logfile").
```

# Read log #

How to read log entries from a log file which created by logw module? You can use logr. Here is a simple example:
```
N = 2, %% How many entries to read.
logr:get("Logfile", "Client1", N).
```

You will get a result like this:
```
{ok, [<<"Test1">>, <<"Test2">>], {position, {0, 0}}
```

It means you get two log entries (<<"Test1">>, <<"Test2">>) from position {0, 0} (that is, start of the log file).

If you continue to call logr:get/3, EOF may be reached. An eof atom will be the result:
```
eof
```

You may notice that logr have a new concept: Client. The following will introduce it.

## What is a Client? ##

You know, At the same time a log file may be read by many applications. And these applications are clients.

NOTE: an application (that is, a client) may create many threads (or processes) to read the log file. Theses threads (or processes) have the same "read position". However, two applications should have two "read position", and do their works without interference.

So, In one word, a client means a "read position".

To get current "read position" of a client, you can use the following code:
```
logr:tell("Logfile", "Client1").
```

You will get a result like this:
```
{ok, {position, {1, 26}}
```

And, you can seek "read position" to somewhere. For example:
```
logr:position("Logfile", "Client1", #position{fileNo=1, offset=26}).
%% This is same as: logr:position("Logfile", "Client", {position, 1, 26}).
```

And, you can seek "read position" to start of log file, by using logr:reset/2:
```
logr:reset("Logfile", "Client1").
```

# Log settings #

## basePath ##

As default, log system (see  [issue #5](https://code.google.com/p/erlana/issues/detail?id=#5)) put log file into current directory. But you can reconfigure the base data path by setting a environment variable (see [issue #7](https://code.google.com/p/erlana/issues/detail?id=#7)):
```
export LogDataBasePath=/home/my/logdata
```

After doing this, you can enter erlang shell, and use the following code to ensure your change is affected:
```
logr:i().
```

If you see the following output:
```
[{basePath, "/home/my/logdata"}]
```

Congratulations for the success. If you see the following output:
```
[{basePath, "."}]
```

You should check where is wrong. For example, maybe you make a typo.

# Source code #

  * [logr.erl](http://code.google.com/p/erlana/source/browse/trunk/src/log/logr.erl)
  * [logw.erl](http://code.google.com/p/erlana/source/browse/trunk/src/log/logw.erl)
  * [log.hrl](http://code.google.com/p/erlana/source/browse/trunk/src/log/log.hrl)