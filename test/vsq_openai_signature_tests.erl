-module(vsq_openai_signature_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test vector from the Standard Webhooks reference implementation
-define(SECRET, <<"whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw">>).
-define(MSG_ID, <<"msg_p5jXN8AQM9LWM0D4loKWxJek">>).
-define(TIMESTAMP, <<"1614265330">>).
-define(BODY, <<"{\"test\": 2432232314}">>).
-define(SIGNATURE, <<"v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=">>).
-define(OTHER_SIGNATURE, <<"v1,Ceo5qEr07ixe2NLpvHk3FH9bwy/WavXrAFQ/9tdO6mc=">>).

-spec decode_secret_test_() -> [tuple()].
decode_secret_test_() ->
    [{"Secret with and without whsec_ prefix decodes to the same key"
     ,?_assertEqual(vsq_openai_signature:decode_secret(?SECRET)
                   ,vsq_openai_signature:decode_secret(<<"MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw">>)
                   )
     }
    ,{"Undecodable secret is rejected"
     ,?_assertEqual('error', vsq_openai_signature:decode_secret(<<"whsec_!!!">>))
     }
    ,{"Empty secret is rejected"
     ,?_assertEqual('error', vsq_openai_signature:decode_secret(<<"whsec_">>))
     }
    ,{"Missing secret is rejected"
     ,?_assertEqual('error', vsq_openai_signature:decode_secret(<<>>))
     }
    ].

-spec verify_test_() -> [tuple()].
verify_test_() ->
    [{"Reference vector is accepted"
     ,?_assertEqual('ok', verify(?SIGNATURE))
     }
    ,{"Any matching entry among several signatures is accepted"
     ,?_assertEqual('ok', verify(<<?OTHER_SIGNATURE/binary, " ", ?SIGNATURE/binary>>))
     }
    ,{"Wrong signature is rejected"
     ,?_assertEqual({'error', 'no_match'}, verify(?OTHER_SIGNATURE))
     }
    ,{"Signature of different length is rejected"
     ,?_assertEqual({'error', 'no_match'}, verify(<<"v1,abc">>))
     }
    ,{"Non-v1 entries are ignored"
     ,?_assertEqual({'error', 'no_match'}, verify(<<"v2,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=">>))
     }
    ,{"Empty signature header is rejected"
     ,?_assertEqual({'error', 'no_match'}, verify(<<>>))
     }
    ,{"Modified body is rejected"
     ,?_assertEqual({'error', 'no_match'}
                   ,vsq_openai_signature:verify(key(), ?MSG_ID, ?TIMESTAMP, <<"{\"test\": 2432232315}">>, ?SIGNATURE)
                   )
     }
    ,{"Modified message id is rejected"
     ,?_assertEqual({'error', 'no_match'}
                   ,vsq_openai_signature:verify(key(), <<"msg_other">>, ?TIMESTAMP, ?BODY, ?SIGNATURE)
                   )
     }
    ,{"Modified timestamp is rejected"
     ,?_assertEqual({'error', 'no_match'}
                   ,vsq_openai_signature:verify(key(), ?MSG_ID, <<"1614265331">>, ?BODY, ?SIGNATURE)
                   )
     }
    ,{"Wrong key is rejected"
     ,?_assertEqual({'error', 'no_match'}
                   ,vsq_openai_signature:verify(<<"other secret">>, ?MSG_ID, ?TIMESTAMP, ?BODY, ?SIGNATURE)
                   )
     }
    ].

key() ->
    {'ok', Key} = vsq_openai_signature:decode_secret(?SECRET),
    Key.

verify(SignatureHeader) ->
    vsq_openai_signature:verify(key(), ?MSG_ID, ?TIMESTAMP, ?BODY, SignatureHeader).
