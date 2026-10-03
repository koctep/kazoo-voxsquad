%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2022, 2600Hz
%%% @doc
%%% @end
%%%-----------------------------------------------------------------------------
-module(vsq_call).

-behaviour(gen_server).

-export([handle_webhook/2]).
-export([handle_channel_destroy/2]).

-export([spec/0]).
-export([start_link/1]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,terminate/2
        ,code_change/3
        ]).

-ifdef(TEST).
-export([verify_openai_webhook/2]).
-endif.

-include("voxsquad.hrl").

-record(?MODULE, {call_id           :: kz_term:ne_binary()
                 ,provider_id       :: kz_term:api_binary()
                 ,provider          :: kz_term:ne_binary()
                 ,config            :: kz_json:object()
                 ,call              :: kapps_call:call()
                 ,msg_id            :: kz_term:ne_binary()
                 ,server_id         :: kz_term:ne_binary()
                 ,replied = 'false' :: boolean()
                 }).
-type state() :: #?MODULE{}.

%%==============================================================================
%% API functions
%%==============================================================================

-spec handle_webhook(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_webhook(JObj0, _Props) ->
    CallId = kz_api:call_id(JObj0),
    kz_util:put_callid(CallId),
    JObj = kz_json:to_map(JObj0),
    cast(CallId, {'webhook', JObj}).

-spec handle_channel_destroy(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_channel_destroy(JObj, _Props) ->
    CallId = kz_api:call_id(JObj),
    kz_util:put_callid(CallId),
    case kz_json:get_value([<<"Custom-SIP-Headers">>, <<"X-VSQ-Call-ID">>], JObj) of
        <<VsqCallId/binary>> ->
            cast(VsqCallId, {'CHANNEL_DESTROY', CallId});
        'undefined' ->
            cast(CallId, {'CHANNEL_DESTROY', CallId})
    end.

cast(CallId, Msg) ->
    case gproc:where(?GPROC_NAME(CallId)) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, Msg);
        _ ->
            'ok'
    end.

-spec spec() -> kz_types:sup_child_spec().
spec() ->
    ?WORKER_TYPE(?MODULE, 'temporary').

-spec start_link(kz_json:object()) -> kz_types:startlink_ret().
start_link(JObj) ->
    gen_server:start_link(?MODULE, [JObj], []).

-spec init([kz_json:object()]) -> {'ok', state()} | 'ignore'.
init([JObj]) ->
    Call = kapps_call:from_json(kz_json:get_value(<<"Call">>, JObj)),
    CallId = kapps_call:call_id(Call),
    kz_util:put_callid(CallId),
    lager:debug("init"),
    gproc:reg(?GPROC_NAME(CallId)),
    Provider = kz_json:get_value(<<"Provider">>, JObj),
    Config = kz_json:to_map(kz_json:get_value(<<"Config">>, JObj)),
    MsgId = kz_json:get_value(<<"Msg-ID">>,JObj),
    ServerId = kz_json:get_value(<<"Server-ID">>, JObj),
    State = #?MODULE{provider = Provider
                    ,config = Config
                    ,call = Call
                    ,call_id = CallId
                    ,msg_id = MsgId
                    ,server_id = ServerId
                    },
    on_init(State).

-spec handle_call(any(), any(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(Msg, _From, State) ->
    lager:warning("unhandled call ~p", [Msg]),
    Reply = {'error', 'unhandled'},
    {'reply', Reply, State}.

-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'webhook', JObj}, State) ->
    NewState = on_webhook(State, JObj),
    {'noreply', NewState};
handle_cast({'CHANNEL_DESTROY', CallId}, State = #?MODULE{call_id = CallId}) ->
    NewState = maybe_reply(State, <<"hangup">>),
    {'stop', 'normal', NewState};
handle_cast({'CHANNEL_DESTROY', _OtherLegId}, State = #?MODULE{call_id = _CallId}) ->
    NewState = maybe_reply(State, <<"disconnected">>),
    {'stop', 'normal', NewState};
handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {'noreply', State}.

-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Msg, State) ->
    lager:warning("unhandled msg ~p", [_Msg]),
    {'noreply', State}.

-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, State) ->
    maybe_reply(State, <<"terminated">>),
    'ok'.

-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

on_init(#?MODULE{provider = <<"openai">>
                ,config = Config
                } = State0) ->
    case vsq_openai_signature:decode_secret(maps:get(<<"webhook_secret">>, Config, <<>>)) of
        {'ok', Key} ->
            State1 = State0#?MODULE{config = Config#{<<"webhook_secret">> => Key}},
            NewState = bridge_to_openai(State1),
            {'ok', NewState};
        'error' ->
            lager:error("webhook_secret is missing or not valid base64, not bridging"),
            _ = maybe_reply(State0, <<"invalid_config">>),
            'ignore'
    end.

bridge_to_openai(#?MODULE{call = Call
                         ,config = #{<<"project_id">> := ProjectId} = Config
                         } = State) ->
    Region = maps:get(<<"region">>, Config, <<"us">>),
    Hostname = case Region of
                   _ when Region =:= <<"us">> ->
                       <<"sip.api.openai.com">>;
                   <<"eu">> ->
                       <<"sip-eu.api.openai.com">>;
                   _ ->
                       lager:warning("invalid region: ~p, using US region", [Region]),
                       <<"sip.api.openai.com">>
               end,
    SipUri = <<"sip:", ProjectId/binary, "@", Hostname/binary, ";transport=tls">>,
    CCVs = #{<<"Account-ID">> => kapps_call:account_id(Call)},
    CSVs = #{<<"X-VSQ-Call-ID">> => kapps_call:call_id(Call)},
    Endpoint = kz_json:from_map(#{<<"Invite-Format">> => <<"route">>
                                 ,<<"Route">> => SipUri
                                 ,<<"Endpoint-Type">> => <<"sip">>
                                 ,<<"Custom-Channel-Vars">> => CCVs
                                 ,<<"Custom-SIP-Headers">> => CSVs
                                 }),
    lager:debug("bridging to ~s", [SipUri]),
    kapps_call_command:bridge([Endpoint], Call),
    State.

on_webhook(#?MODULE{provider_id = <<_/binary>> = ProviderId} = State, _Webhook) ->
    lager:info("ignoring duplicate webhook, call already accepted as ~s", [ProviderId]),
    State;
on_webhook(#?MODULE{provider = Provider = <<"openai">>
                   ,config = #{<<"webhook_secret">> := Key}
                   } = State
          ,#{<<"Provider">> := Provider} = Webhook
          ) ->
    case verify_openai_webhook(Key, Webhook) of
        'ok' ->
            accept(State, Webhook);
        {'error', Reason} ->
            lager:warning("rejecting webhook, signature verification failed: ~p", [Reason]),
            State
    end.

verify_openai_webhook(Key, #{<<"Raw-Body">> := RawBody
                            ,<<"Webhook-ID">> := Id
                            ,<<"Webhook-Timestamp">> := Timestamp
                            ,<<"Webhook-Signature">> := Signature
                            }) ->
    vsq_openai_signature:verify(Key, Id, Timestamp, RawBody, Signature);
verify_openai_webhook(_Key, #{<<"Raw-Body">> := _}) ->
    {'error', 'missing_signature_headers'};
verify_openai_webhook(_Key, _Webhook) ->
    lager:warning("webhook has no raw body, signature verification is skipped"),
    'ok'.

accept(#?MODULE{provider = <<"openai">>
               ,config = #{<<"api_key">> := ApiKey
                          ,<<"prompt">> := Prompt
                          }
               } = State
      ,#{<<"OpenAI-Leg-ID">> := OpenAILegId}
      ) ->
    Url = <<"https://api.openai.com/v1/realtime/calls/"
           ,(kz_http_util:urlencode(OpenAILegId))/binary
           ,"/accept"
          >>,
    Headers = [{<<"Authorization">>, <<"Bearer ", ApiKey/binary>>}
              ,{<<"Content-Type">>, <<"application/json">>}
              ],
    Data0 = #{<<"type">> => <<"realtime">>
             ,<<"model">> => <<"gpt-realtime">>
             ,<<"instructions">> => Prompt
             },
    Data = kz_json:from_map(Data0),
    Response = kz_http:post(Url, Headers, Data),
    lager:debug("accept response ~p", [Response]),
    State#?MODULE{provider_id = OpenAILegId}.

maybe_reply(State = #?MODULE{server_id = ServerId, msg_id = MsgId, replied = 'false'}, Reply) ->
    lager:debug("sending reply ~p", [Reply]),
    Response0 = kz_json:from_map(#{<<"Response">> => Reply}),
    Response = kz_json:set_values(kz_api:default_headers(?APP_NAME, ?APP_VERSION), Response0),
    kapi_voxsquad:publish_response(ServerId, MsgId, Response),
    State#?MODULE{replied = 'true'};
maybe_reply(State, _Reply) ->
    State.
