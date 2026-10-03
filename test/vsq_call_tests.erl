-module(vsq_call_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw">>).
-define(MSG_ID, <<"msg_p5jXN8AQM9LWM0D4loKWxJek">>).
-define(TIMESTAMP, <<"1614265330">>).
-define(BODY, <<"{\"type\": \"realtime.call.incoming\"}">>).

-spec verify_openai_webhook_test_() -> [tuple()].
verify_openai_webhook_test_() ->
    [{"Valid signature is accepted"
     ,?_assertEqual('ok', vsq_call:verify_openai_webhook(key(), signed_webhook()))
     }
    ,{"Invalid signature is rejected"
     ,?_assertEqual({'error', 'no_match'}
                   ,vsq_call:verify_openai_webhook(key(), webhook(<<"v1,Ceo5qEr07ixe2NLpvHk3FH9bwy/WavXrAFQ/9tdO6mc=">>))
                   )
     }
    ,{"Webhook without Raw-Body skips verification"
     ,?_assertEqual('ok', vsq_call:verify_openai_webhook(key(), maps:remove(<<"Raw-Body">>, webhook(<<"v1,bogus">>))))
     }
    ,{"Missing signature headers are rejected"
     ,?_assertEqual({'error', 'missing_signature_headers'}
                   ,vsq_call:verify_openai_webhook(key(), maps:remove(<<"Webhook-Signature">>, signed_webhook()))
                   )
     }
    ].

key() ->
    {'ok', Key} = vsq_openai_signature:decode_secret(?SECRET),
    Key.

signed_webhook() ->
    webhook(sign(key(), ?MSG_ID, ?TIMESTAMP, ?BODY)).

sign(Key, MsgId, Timestamp, RawBody) ->
    Signed = <<MsgId/binary, ".", Timestamp/binary, ".", RawBody/binary>>,
    Mac = base64:encode(crypto:mac('hmac', 'sha256', Key, Signed)),
    <<"v1,", Mac/binary>>.

webhook(Signature) ->
    #{<<"Provider">> => <<"openai">>
     ,<<"Webhook-ID">> => ?MSG_ID
     ,<<"Webhook-Timestamp">> => ?TIMESTAMP
     ,<<"Webhook-Signature">> => Signature
     ,<<"Raw-Body">> => ?BODY
     }.
