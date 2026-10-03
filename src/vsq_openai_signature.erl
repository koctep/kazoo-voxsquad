%%%-----------------------------------------------------------------------------
%%% @doc Verification of Standard Webhooks signatures (used by OpenAI webhooks).
%%%
%%% The signed content is `<<MsgId/binary, ".", Timestamp/binary, ".", Body/binary>>',
%%% signed with HMAC-SHA256 using the base64-decoded secret (an optional
%%% `whsec_' prefix is stripped, see `decode_secret/1'). The signature header
%%% holds space-separated `v1,<base64>' entries; any matching entry is accepted.
%%% @end
%%%-----------------------------------------------------------------------------
-module(vsq_openai_signature).

-export([decode_secret/1
        ,verify/5
        ]).

-define(SECRET_PREFIX, "whsec_").

%%------------------------------------------------------------------------------
%% @doc Decode a `whsec_<base64>' (or bare base64) secret into the HMAC key.
%% @end
%%------------------------------------------------------------------------------
-spec decode_secret(binary()) -> {'ok', binary()} | 'error'.
decode_secret(<<?SECRET_PREFIX, Encoded/binary>>) ->
    decode_secret(Encoded);
decode_secret(<<>>) ->
    'error';
decode_secret(Encoded) ->
    try base64:decode(Encoded) of
        <<>> -> 'error';
        Key -> {'ok', Key}
    catch
        _:_ -> 'error'
    end.

%%------------------------------------------------------------------------------
%% @doc Verify a webhook signature header against the raw request body.
%% @end
%%------------------------------------------------------------------------------
-spec verify(binary(), binary(), binary(), binary(), binary()) -> 'ok' | {'error', 'no_match'}.
verify(Key, MsgId, Timestamp, RawBody, SignatureHeader) ->
    Expected = compute(Key, MsgId, Timestamp, RawBody),
    case lists:any(fun(Candidate) -> signature_matches(Expected, Candidate) end
                  ,v1_signatures(SignatureHeader)
                  )
    of
        'true' -> 'ok';
        'false' -> {'error', 'no_match'}
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

-spec compute(binary(), binary(), binary(), binary()) -> binary().
compute(Key, MsgId, Timestamp, RawBody) ->
    Signed = <<MsgId/binary, ".", Timestamp/binary, ".", RawBody/binary>>,
    base64:encode(crypto:mac('hmac', 'sha256', Key, Signed)).

-spec v1_signatures(binary()) -> [binary()].
v1_signatures(SignatureHeader) ->
    [Signature
     || Entry <- binary:split(SignatureHeader, <<" ">>, ['global', 'trim_all']),
        [<<"v1">>, Signature] <- [binary:split(Entry, <<",">>)]
    ].

-spec signature_matches(binary(), binary()) -> boolean().
signature_matches(A, B) when byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
signature_matches(_A, _B) ->
    'false'.
