-module(cb_voxsquad_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw">>).
-define(MSG_ID, <<"msg_p5jXN8AQM9LWM0D4loKWxJek">>).
-define(OPENAI_CALL_ID, <<"rtc_u1_9c6574da8b8a41a18da9308f4ad974ce">>).
-define(KAZOO_CALL_ID, <<"call-1@10.0.0.1">>).

-spec validate_test_() -> any().
validate_test_() ->
    {'setup'
    ,fun setup/0
    ,fun cleanup/1
    ,fun(_) ->
             [{"Valid incoming call webhook is accepted"
              ,fun valid_webhook/0
              }
             ,{"Header name of X-VSQ-Call-ID is case-insensitive"
              ,fun case_insensitive_header/0
              }
             ,{"Missing signature headers are rejected"
              ,fun missing_headers/0
              }
             ,{"Empty raw body is rejected"
              ,fun empty_raw_body/0
              }
             ,{"Missing X-VSQ-Call-ID is rejected"
              ,?_assertEqual(400, error_code(validate([])))
              }
             ,{"Duplicated X-VSQ-Call-ID is rejected"
              ,?_assertEqual(400, error_code(validate([vsq_header(<<"X-VSQ-Call-ID">>, ?KAZOO_CALL_ID)
                                                      ,vsq_header(<<"X-VSQ-Call-ID">>, <<"other">>)
                                                      ])))
              }
             ,{"Missing OpenAI call_id is rejected"
              ,fun missing_call_id/0
              }
             ,{"Other event types are acknowledged and ignored"
              ,fun other_event_type/0
              }
             ,{"Without cb_context:raw_req_body/1 the webhook is published without Raw-Body"
              ,fun raw_req_body_not_exported/0
              }
             ]
     end
    }.

setup() ->
    meck:new('kz_amqp_worker', ['passthrough']),
    meck:expect('kz_amqp_worker', 'cast', fun(_Req, _PubFun) -> 'ok' end),
    meck:new('kz_module', ['passthrough']).

cleanup(_) ->
    meck:unload(['kz_amqp_worker', 'kz_module']).

valid_webhook() ->
    Context = validate([vsq_header(<<"X-VSQ-Call-ID">>, ?KAZOO_CALL_ID)]),
    ?assertEqual('success', cb_context:resp_status(Context)),
    Webhook = cb_context:fetch(Context, 'voxsquad_webhook'),
    ?assertMatch(#{call_id := ?KAZOO_CALL_ID
                  ,openai_call_id := ?OPENAI_CALL_ID
                  ,webhook_id := ?MSG_ID
                  }
                ,Webhook
                ),
    ?assertEqual(body(), maps:get('raw_body', Webhook)),
    Req = post(Context),
    ?assertEqual(body(), kz_json:get_value(<<"Raw-Body">>, Req)),
    ?assertEqual(?KAZOO_CALL_ID, kz_json:get_value(<<"Call-ID">>, Req)),
    ?assertEqual(?OPENAI_CALL_ID, kz_json:get_value(<<"OpenAI-Leg-ID">>, Req)).

case_insensitive_header() ->
    Context = validate([vsq_header(<<"x-vsq-call-id">>, ?KAZOO_CALL_ID)]),
    ?assertEqual('success', cb_context:resp_status(Context)).

missing_headers() ->
    [?assertEqual(400, error_code(cb_voxsquad:validate(context(maps:remove(Header, headers()), body()), <<"openai">>)))
     || Header <- [<<"webhook-id">>, <<"webhook-timestamp">>, <<"webhook-signature">>]
    ].

empty_raw_body() ->
    ?assertEqual(400, error_code(cb_voxsquad:validate(context(headers(), <<>>), <<"openai">>))).

missing_call_id() ->
    Body = body(<<"realtime.call.incoming">>, 'undefined', [vsq_header(<<"X-VSQ-Call-ID">>, ?KAZOO_CALL_ID)]),
    ?assertEqual(400, error_code(cb_voxsquad:validate(context(headers(), Body), <<"openai">>))).

other_event_type() ->
    Body = body(<<"realtime.call.ended">>, ?OPENAI_CALL_ID, []),
    Context = cb_voxsquad:validate(context(headers(), Body), <<"openai">>),
    ?assertEqual('success', cb_context:resp_status(Context)),
    ?assertEqual('undefined', cb_context:fetch(Context, 'voxsquad_webhook')),
    meck:reset('kz_amqp_worker'),
    _ = cb_voxsquad:post(Context, <<"openai">>),
    ?assertEqual(0, meck:num_calls('kz_amqp_worker', 'cast', '_')).

raw_req_body_not_exported() ->
    meck:expect('kz_module', 'is_exported'
               ,fun('cb_context', 'raw_req_body', 1) -> 'false';
                   (M, F, A) -> meck:passthrough([M, F, A])
                end
               ),
    try
        Context = validate([vsq_header(<<"X-VSQ-Call-ID">>, ?KAZOO_CALL_ID)]),
        ?assertEqual('success', cb_context:resp_status(Context)),
        Req = post(Context),
        ?assertEqual('undefined', kz_json:get_value(<<"Raw-Body">>, Req)),
        ?assertEqual(?MSG_ID, kz_json:get_value(<<"Webhook-ID">>, Req))
    after
        meck:expect('kz_module', 'is_exported', fun(M, F, A) -> meck:passthrough([M, F, A]) end)
    end.

%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------

validate(SipHeaders) ->
    Body = body(<<"realtime.call.incoming">>, ?OPENAI_CALL_ID, SipHeaders),
    cb_voxsquad:validate(context(headers(), Body), <<"openai">>).

post(Context) ->
    meck:reset('kz_amqp_worker'),
    _ = cb_voxsquad:post(Context, <<"openai">>),
    meck:capture('last', 'kz_amqp_worker', 'cast', ['_', '_'], 1).

context(Headers, RawBody) ->
    ReqJson = case RawBody of
                  <<>> -> kz_json:new();
                  _ -> kz_json:decode(RawBody)
              end,
    cb_context:setters(cb_context:new()
                      ,[{fun cb_context:set_req_headers/2, Headers}
                       ,{fun cb_context:set_req_json/2, ReqJson}
                       ,{fun cb_context:set_req_data/2, kz_json:get_json_value(<<"data">>, ReqJson, kz_json:new())}
                       ,{fun cb_context:set_raw_req_body/2, RawBody}
                       ]
                      ).

headers() ->
    Timestamp = <<"1614265330">>,
    {'ok', Key} = vsq_openai_signature:decode_secret(?SECRET),
    Signature = sign(Key, ?MSG_ID, Timestamp, body()),
    #{<<"webhook-id">> => ?MSG_ID
     ,<<"webhook-timestamp">> => Timestamp
     ,<<"webhook-signature">> => Signature
     }.

sign(Key, MsgId, Timestamp, RawBody) ->
    Signed = <<MsgId/binary, ".", Timestamp/binary, ".", RawBody/binary>>,
    Mac = base64:encode(crypto:mac('hmac', 'sha256', Key, Signed)),
    <<"v1,", Mac/binary>>.

body() ->
    body(<<"realtime.call.incoming">>, ?OPENAI_CALL_ID, [vsq_header(<<"X-VSQ-Call-ID">>, ?KAZOO_CALL_ID)]).

body(Type, OpenAICallId, SipHeaders) ->
    kz_json:encode(kz_json:from_list([{<<"object">>, <<"event">>}
                                     ,{<<"type">>, Type}
                                     ,{<<"data">>, kz_json:from_list([{<<"call_id">>, OpenAICallId}
                                                                     ,{<<"sip_headers">>, SipHeaders}
                                                                     ])
                                      }
                                     ])).

vsq_header(Name, Value) ->
    kz_json:from_list([{<<"name">>, Name}, {<<"value">>, Value}]).

error_code(Context) ->
    cb_context:resp_error_code(Context).
