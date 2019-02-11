%% @doc Cross-Origin Resource Sharing (CORS) middleware.
%%
%% Policy is defined through callbacks contained in a module named by
%% the <em>cors_policy</em> environment value.
%%
%% @see http://www.w3.org/TR/cors/
-module(cowboy_cors).
-behaviour(cowboy_middleware).

-export([execute/2]).

-record(state, {
          env                    :: cowboy_middleware:env(),
          method                 :: binary(),
          origin = <<>>          :: binary(),
          request_method  = <<>> :: binary(),
          preflight = false      :: boolean(),
          allowed_methods = []   :: [binary()],
          allowed_headers = [<<"origin">>]   :: [binary()],
          request_headers_present = true :: boolean(), 

          %% Policy handler.
          policy               :: atom(),
          policy_state         :: any()
}).

%% @private
execute(Req, Env) ->
    Policy = maps:get(cors_policy, Env),
    Method = cowboy_req:method(Req),
    origin_present(Req, #state{env = Env, policy = Policy, method = Method}).

%% CORS specification only applies to requests with an `Origin' header.
origin_present(Req, State) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
            terminate(Req, State);
        Origin ->
            policy_init(Req, State#state{origin = Origin})
    end.

policy_init(Req, State = #state{policy = Policy}) ->
    try Policy:policy_init(Req) of
        {ok, Req1, PolicyState} ->
            allowed_origins(Req1, State#state{policy_state = PolicyState})
    catch Class:Reason:Stacktrace ->
        error_logger:error_msg(
            "** Cowboy CORS policy ~p terminating in ~p/~p~n"
            "   for the reason ~p:~p~n"
            "** Request was ~p~n** Stacktrace: ~p~n~n",
            [Policy, policy_init, 1, Class, Reason, Req, Stacktrace]
        ),
        error_terminate(Req, State)
    end.

%% allowed_origins/2 should return a list of origins or the atom '*'
allowed_origins(Req, State = #state{origin = Origin}) ->
    case call(Req, State, allowed_origins, []) of
        {'*', PolicyState} ->
            request_method(Req, State#state{policy_state = PolicyState});
        {List, PolicyState} ->
            case lists:member(Origin, List) of
                true ->
                    request_method(Req, State#state{policy_state = PolicyState});
                false ->
                    terminate(Req, State#state{policy_state = PolicyState})
            end
    end.

request_method(Req, State = #state{method = <<"OPTIONS">>}) ->
    case cowboy_req:header(<<"access-control-request-method">>, Req) of
        undefined ->
            %% This is not a pre-flight request, but an actual request.
            exposed_headers(Req, State);
        Data ->
            cowboy_cors_utils:token(
                Data,
                fun (<<>>, Method) ->
                        request_headers(Req, State#state{preflight = true, request_method = Method});
                    (_, _) ->
                        terminate(Req, State)
                end
            )
    end;
request_method(Req, State) ->
    exposed_headers(Req, State).

request_headers(Req, State) ->
    ReqHeadersPresent = case cowboy_req:header(<<"access-control-request-headers">>, Req, undefined) of
        undefined ->
            false;
        _ ->
            true
    end,
    max_age(Req, State#state{request_headers_present = ReqHeadersPresent}).

%% max_age/2 should return a non-negative integer or the atom undefined
max_age(Req, State) ->
    case call(Req, State, max_age, undefined) of
        {MaxAge, PolicyState} when is_integer(MaxAge) andalso MaxAge >= 0 ->
            MaxAgeBin = list_to_binary(integer_to_list(MaxAge)),
            Req1 = cowboy_req:set_resp_header(<<"access-control-max-age">>, MaxAgeBin, Req),
            allowed_methods(Req1, State#state{policy_state = PolicyState});
        {undefined, PolicyState} ->
            allowed_methods(Req, State#state{policy_state = PolicyState})
    end.

%% allow_methods/2 should return a list of binary method names
allowed_methods(Req, State = #state{request_method = Method}) ->
    {List, PolicyState} = call(Req, State, allowed_methods, []),
    case lists:member(Method, List) of
        false ->
            terminate(Req, State#state{policy_state = PolicyState});
        true ->
            allowed_headers(Req, State#state{policy_state = PolicyState, allowed_methods = List})
    end.

% Seems like we don't need to validate headers anymore
allowed_headers(Req, State = #state{allowed_headers = Allowed}) ->
    {List, PolicyState} = call(Req, State, allowed_headers, []),
    set_allow_methods(Req, State#state{policy_state = PolicyState, allowed_headers = Allowed ++ List}).

set_allow_methods(Req, State = #state{allowed_methods = Methods}) ->
    Req1 = cowboy_req:set_resp_header(<<"access-control-allow-methods">>, header_list(Methods), Req),
    set_allow_headers(Req1, State).

set_allow_headers(Req0, State = #state{allowed_headers = Allowed, request_headers_present = ReqHeadersPresent}) ->
    Headers = case ReqHeadersPresent of
        true ->
            header_list(Allowed);
        false ->
            <<>>
    end,
    Req = cowboy_req:set_resp_header(<<"access-control-allow-headers">>, Headers, Req0),
    allow_credentials(Req, State).


%% exposed_headers/2 should return a list of binary header names.
exposed_headers(Req, State) ->
    {List, PolicyState} = call(Req, State, exposed_headers, []),
    Req1 = set_exposed_headers(Req, List),
    allow_credentials(Req1, State#state{policy_state = PolicyState}).

set_exposed_headers(Req, []) ->
    Req;
set_exposed_headers(Req, Headers) ->
    Bin = header_list(Headers),
    cowboy_req:set_resp_header(<<"access-control-expose-headers">>, Bin, Req).

%% allow_credentials/1 should return true or false.
allow_credentials(Req, State) ->
    expect(Req, State, allow_credentials, false,
        fun if_not_allow_credentials/2, fun if_allow_credentials/2).

%% If credentials are allowed, then the value of
%% `Access-Control-Allow-Origin' is limited to the requesting origin.
if_allow_credentials(Req, State = #state{origin = Origin}) ->
    Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
    Req2 = cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req1),
    Req3 = cowboy_req:set_resp_header(<<"vary">>, <<"origin">>, Req2),
    terminate(Req3, State).

if_not_allow_credentials(Req, State = #state{origin = Origin}) ->
    %% To simplify conformance with the requirement that "*" is only
    %% valid if credentials are not allowed, we will only ever return
    %% the origin of the request.
    Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
    Req2 = cowboy_req:set_resp_header(<<"vary">>, <<"origin">>, Req1),
    terminate(Req2, State).

expect(Req, State, Callback, Expected, OnTrue, OnFalse) ->
    case call(Req, State, Callback, Expected) of
        {Expected, PolicyState} ->
            OnTrue(Req, State#state{policy_state = PolicyState});
        {_Unexpected, PolicyState} ->
            OnFalse(Req, State#state{policy_state = PolicyState})
    end.

call(Req, State = #state{policy = Policy, policy_state = PolicyState}, Callback, Default) ->
    case erlang:function_exported(Policy, Callback, 2) of
        true ->
            try
                Policy:Callback(Req, PolicyState)
            catch Class:Reason:Stacktrace ->
                error_logger:error_msg(
                    "** Cowboy CORS policy ~p terminating in ~p/~p~n"
                    "   for the reason ~p:~p~n"
                    "** Request was ~p~n** Stacktrace: ~p~n~n",
                    [Policy, Callback, 2, Class, Reason, Req, Stacktrace]
                ),
                error_terminate(Req, State)
            end;
        false ->
            {Default, PolicyState}
    end.

terminate(Req, #state{preflight = true}) ->
    Req1 = cowboy_req:reply(200, cowboy_req:headers(Req), [], Req),
    {stop, Req1};
terminate(Req, #state{env = Env}) ->
    {ok, Req, Env}.

-spec error_terminate(cowboy_req:req(), #state{}) -> no_return().
error_terminate(_Req, _State) ->
    erlang:throw({?MODULE, error}).

%% create a comma-separated list for a header value
header_list(Values) ->
    header_list(Values, <<>>).

header_list([], Acc) ->
    Acc;
header_list([Value], Acc) ->
    <<Acc/binary, Value/binary>>;
header_list([Value | Rest], Acc) ->
    header_list(Rest, <<Acc/binary, Value/binary, ",">>).
