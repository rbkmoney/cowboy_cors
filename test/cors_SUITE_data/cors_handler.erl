-module(cors_handler).
-behaviour(cowboy_handler).

-export([init/2, terminate/3]).

init(Req, _Opts) ->
    handle(Req, undefined_state).

handle(Req, State) ->
    Headers = #{<<"X-Exposed">> => <<"exposed">>, <<"X-Hidden">> => <<"hidden">>},
    Req1 = cowboy_req:reply(200, Headers, [], Req),
    {ok, Req1, State}.

terminate(_Reason, _Req, _State) ->
    ok.
