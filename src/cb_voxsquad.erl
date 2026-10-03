-module(cb_voxsquad).

-export([init/0
        ,authenticate/2
        ,authorize/2
        ,allowed_methods/1
        ,resource_exists/1
        ,validate/2
        ,post/2
        ]).

-include_lib("crossbar/src/crossbar.hrl").

-define(OPENAI_CALL_INCOMING, <<"realtime.call.incoming">>).
-define(VSQ_CALL_ID_HEADER, <<"x-vsq-call-id">>).
-define(WEBHOOK_KEY, 'voxsquad_webhook').

-type webhook() :: #{call_id := kz_term:ne_binary()
                    ,openai_call_id := kz_term:ne_binary()
                    ,webhook_id := kz_term:ne_binary()
                    ,webhook_timestamp := kz_term:ne_binary()
                    ,webhook_signature := kz_term:ne_binary()
                    ,raw_body := binary() | 'undefined'
                    }.
-type webhook_error() :: {'error', kz_json:get_key(), kz_term:ne_binary(), kz_term:ne_binary()}.
-type routine_result() :: {'ok', map()} | {'ignore', kz_term:api_binary()} | webhook_error().
-type routine() :: fun((cb_context:context(), map()) -> routine_result()).

%%%=============================================================================
%%% API
%%%=============================================================================

-spec init() -> 'ok'.
init() ->
    _ = crossbar_bindings:bind(<<"*.authenticate.voxsquad">>, ?MODULE, 'authenticate'),
    _ = crossbar_bindings:bind(<<"*.authorize.voxsquad">>, ?MODULE, 'authorize'),
    _ = crossbar_bindings:bind(<<"*.allowed_methods.voxsquad">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.voxsquad">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.validate.voxsquad">>, ?MODULE, 'validate'),
    _ = crossbar_bindings:bind(<<"*.execute.post.voxsquad">>, ?MODULE, 'post').

-spec authenticate(cb_context:context(), path_token()) -> {'true', cb_context:context()}.
authenticate(Context, <<"openai">>) ->
    {'true', Context}.

-spec authorize(cb_context:context(), path_token()) -> 'true'.
authorize(_Context, <<"openai">>) ->
    'true'.

-spec allowed_methods(path_token()) -> http_methods().
allowed_methods(<<"openai">>) ->
    [?HTTP_POST].

-spec resource_exists(path_token()) -> 'true'.
resource_exists(<<"openai">>) ->
    'true'.

-spec validate(cb_context:context(), path_token()) -> cb_context:context().
validate(Context, <<"openai">>) ->
    case validate_openai_webhook(Context) of
        {'ok', Webhook} ->
            lager:notice("call ~s received webhook from openai", [maps:get('call_id', Webhook)]),
            Context1 = cb_context:store(Context, ?WEBHOOK_KEY, Webhook),
            cb_context:update_successfully_validated_request(Context1, kz_json:new());
        {'ignore', Type} ->
            lager:debug("ignoring openai webhook of type ~s", [Type]),
            cb_context:update_successfully_validated_request(Context, kz_json:new());
        {'error', Property, Code, Message} ->
            lager:info("rejecting openai webhook: ~s ~s", [Code, Message]),
            cb_context:add_validation_error(Property, Code, Message, Context)
    end.

-spec post(cb_context:context(), path_token()) -> cb_context:context().
post(Context, <<"openai">>) ->
    Webhook = cb_context:fetch(Context, ?WEBHOOK_KEY),
    case kz_amqp_worker:cast(webhook_request(Webhook), fun kapi_voxsquad:publish_webhook/1) of
        'ok' -> Context;
        {'error', _Reason} ->
            lager:error("failed to publish openai webhook: ~p", [_Reason]),
            crossbar_util:response('error', <<"failed to publish webhook">>, 500, Context)
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

-spec validate_openai_webhook(cb_context:context()) -> routine_result().
validate_openai_webhook(Context) ->
    Routines = [fun validate_raw_body/2
               ,fun validate_event_type/2
               ,header_routine(<<"webhook-id">>, 'webhook_id')
               ,header_routine(<<"webhook-timestamp">>, 'webhook_timestamp')
               ,header_routine(<<"webhook-signature">>, 'webhook_signature')
               ,fun validate_openai_call_id/2
               ,fun validate_vsq_call_id/2
               ],
    lists:foldl(fun(Routine, {'ok', Webhook}) -> Routine(Context, Webhook);
                   (_Routine, Result) -> Result
                end
               ,{'ok', #{}}
               ,Routines
               ).

-spec validate_raw_body(cb_context:context(), map()) -> routine_result().
validate_raw_body(Context, Webhook) ->
    validate_raw_body(Context, Webhook, kz_module:is_exported('cb_context', 'raw_req_body', 1)).

-spec validate_raw_body(cb_context:context(), map(), boolean()) -> routine_result().
validate_raw_body(_Context, Webhook, 'false') ->
    lager:warning("cb_context:raw_req_body/1 is not exported, webhook signature verification is skipped"),
    {'ok', Webhook#{raw_body => 'undefined'}};
validate_raw_body(Context, Webhook, 'true') ->
    case cb_context:raw_req_body(Context) of
        <<>> -> {'error', <<"body">>, <<"required">>, <<"webhook body is empty">>};
        RawBody -> {'ok', Webhook#{raw_body => RawBody}}
    end.

-spec validate_event_type(cb_context:context(), map()) -> routine_result().
validate_event_type(Context, Webhook) ->
    case kz_json:get_ne_binary_value(<<"type">>, cb_context:req_json(Context)) of
        ?OPENAI_CALL_INCOMING -> {'ok', Webhook};
        Type -> {'ignore', Type}
    end.

-spec header_routine(kz_term:ne_binary(), atom()) -> routine().
header_routine(Name, Key) ->
    fun(Context, Webhook) ->
            case req_header(Context, Name) of
                'undefined' -> {'error', Name, <<"required">>, <<"header ", Name/binary, " is required">>};
                Value -> {'ok', Webhook#{Key => Value}}
            end
    end.

-spec validate_openai_call_id(cb_context:context(), map()) -> routine_result().
validate_openai_call_id(Context, Webhook) ->
    case kz_json:get_ne_binary_value(<<"call_id">>, cb_context:req_data(Context)) of
        'undefined' -> {'error', <<"call_id">>, <<"required">>, <<"call_id is missing">>};
        OpenAICallId -> {'ok', Webhook#{openai_call_id => OpenAICallId}}
    end.

-spec validate_vsq_call_id(cb_context:context(), map()) -> routine_result().
validate_vsq_call_id(Context, Webhook) ->
    SipHeaders = kz_json:get_list_value(<<"sip_headers">>, cb_context:req_data(Context), []),
    with_vsq_call_id(Webhook, vsq_call_ids(SipHeaders)).

-spec with_vsq_call_id(map(), kz_term:ne_binaries()) -> routine_result().
with_vsq_call_id(Webhook, [CallId]) ->
    {'ok', Webhook#{call_id => CallId}};
with_vsq_call_id(_Webhook, []) ->
    {'error', <<"sip_headers">>, <<"required">>, <<"X-VSQ-Call-ID header is missing">>};
with_vsq_call_id(_Webhook, _CallIds) ->
    {'error', <<"sip_headers">>, <<"invalid">>, <<"X-VSQ-Call-ID header must be present exactly once">>}.

-spec vsq_call_ids(kz_json:objects()) -> kz_term:ne_binaries().
vsq_call_ids(SipHeaders) ->
    lists:filtermap(fun vsq_call_id/1, SipHeaders).

-spec vsq_call_id(kz_json:object()) -> {'true', kz_term:ne_binary()} | 'false'.
vsq_call_id(SipHeader) ->
    Name = kz_json:get_ne_binary_value(<<"name">>, SipHeader),
    Value = kz_json:get_ne_binary_value(<<"value">>, SipHeader),
    is_vsq_call_id(kz_term:to_lower_binary(Name), Value).

-spec is_vsq_call_id(kz_term:api_binary(), kz_term:api_ne_binary()) -> {'true', kz_term:ne_binary()} | 'false'.
is_vsq_call_id(?VSQ_CALL_ID_HEADER, <<_/binary>> = Value) -> {'true', Value};
is_vsq_call_id(_Name, _Value) -> 'false'.

-spec webhook_request(webhook()) -> kz_json:object().
webhook_request(#{call_id := CallId
                 ,openai_call_id := OpenAICallId
                 ,webhook_id := Id
                 ,webhook_timestamp := Timestamp
                 ,webhook_signature := Signature
                 ,raw_body := RawBody
                 }) ->
    Req = kz_json:from_list([{<<"Call-ID">>, CallId}
                            ,{<<"OpenAI-Leg-ID">>, OpenAICallId}
                            ,{<<"Provider">>, <<"openai">>}
                            ,{<<"Webhook-ID">>, Id}
                            ,{<<"Webhook-Timestamp">>, Timestamp}
                            ,{<<"Webhook-Signature">>, Signature}
                            ,{<<"Raw-Body">>, RawBody}
                            ]),
    kz_json:set_values(kz_api:default_headers(?APP_NAME, ?APP_VERSION), Req).

-spec req_header(cb_context:context(), kz_term:ne_binary()) -> iodata() | 'undefined'.
req_header(Context, Name) ->
    non_empty_header(cb_context:req_header(Context, Name)).

-spec non_empty_header(iodata() | 'undefined') -> iodata() | 'undefined'.
non_empty_header(<<>>) -> 'undefined';
non_empty_header(Value) -> Value.
