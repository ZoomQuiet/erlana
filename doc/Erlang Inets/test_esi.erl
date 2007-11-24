-module(test_esi).

-export([yahoo/2, test/2]).

yahoo(_Env, _Input) ->
	"Location: http://www.yahoo.com\r\n\r\n".
  
test(Env, Input) ->
[
	"Content-type: text/html\r\n\r\n",
	"<HTML><HEAD><TITLE>Example</TITLE></HEAD>\r\n",
	"<BODY>\n",
	"<B>Self:</B> ", io_lib:format("~p", [self()]), "<BR>\n",
	"<B>Environment:</B> ", io_lib:format("~p",[Env]), "<BR>\n",
	"<B>Input:</B> ", Input, "<BR>\n",
	"<B>Parsed Input:</B> ", io_lib:format("~p",[httpd:parse_query(Input)]), "\n",
	"</BODY></HTML>\n"
].
