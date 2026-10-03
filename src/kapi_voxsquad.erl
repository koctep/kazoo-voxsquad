-module(kapi_voxsquad).

-export([bind_q/2, unbind_q/2
        ,declare_exchanges/0
        ]).

-export([publish_request/1
        ,request_v/1
        ]).
-export([publish_response/3
        ,response_v/1
        ]).

-export([publish_webhook/1
        ,webhook_v/1
        ]).

-include("voxsquad.hrl").

-define(WEBHOOK_ROUTING(Provider, CallId)
       ,kz_binary:join([<<"voxsquad">>, <<"webhook">>, Provider, CallId], <<".">>)
       ).

-spec bind_q(binary(), kz_term:proplist()) -> 'ok'.
bind_q(?SHARED_NAME = Q, _Props) ->
    kz_amqp_util:bind_q_to_targeted(Q);
bind_q(Q, _Props) ->
    kz_amqp_util:bind_q_to_kapps(Q, ?WEBHOOK_ROUTING(<<"*">>, <<"*">>)).

-spec unbind_q(binary(), kz_term:proplist()) -> 'ok'.
unbind_q(?SHARED_NAME = Q, _Props) ->
    kz_amqp_util:unbind_q_from_targeted(Q);
unbind_q(Q, _Props) ->
    kz_amqp_util:unbind_q_from_kapps(Q, ?WEBHOOK_ROUTING(<<"*">>, <<"*">>)).

-spec declare_exchanges() -> 'ok'.
declare_exchanges() ->
    kz_amqp_util:targeted_exchange(),
    kz_amqp_util:kapps_exchange().

-define(REQUEST_HEADERS, [<<"Provider">>, <<"Config">>, <<"Call">>]).
-define(REQUEST_OPT_HEADERS, []).
-define(REQUEST_VALUES, [{<<"Event-Category">>, <<"voxsquad">>}
                        ,{<<"Event-Name">>, <<"request">>}
                        ]).
-define(REQUEST_TYPES, []).
-type request() :: kz_api:proplist().
-spec publish_request(request()) -> 'ok'.
publish_request(Req) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Req, ?REQUEST_VALUES, fun request/1),
    kz_amqp_util:targeted_publish(?SHARED_NAME, Payload).

request(Req) ->
    case request_v(Req) of
        'true' -> kz_api:build_message(Req, ?REQUEST_HEADERS, ?REQUEST_OPT_HEADERS);
        'false' -> {'error', "Failed validate voxsquad request"}
    end.

request_v(Req) ->
    kz_api:validate(Req, ?REQUEST_HEADERS, ?REQUEST_VALUES, ?REQUEST_TYPES).

-define(RESPONSE_HEADERS, [<<"Msg-ID">>, <<"Response">>]).
-define(RESPONSE_OPT_HEADERS, []).
-define(RESPONSE_VALUES, [{<<"Event-Category">>, <<"voxsquad">>}
                         ,{<<"Event-Name">>, <<"response">>}
                         ]).
-define(RESPONSE_TYPES, []).
-type response() :: kz_api:proplist().
-spec publish_response(kz_term:ne_binary(), kz_term:ne_binary(), response()) -> 'ok'.
publish_response(ServerId, MsgId, Response) ->
    Req = kz_json:set_value(<<"Msg-ID">>, MsgId, Response),
    {'ok', Payload} = kz_api:prepare_api_payload(Req, ?RESPONSE_VALUES, fun response/1),
    kz_amqp_util:targeted_publish(ServerId, Payload).

response(Req) ->
    case response_v(Req) of
        'true' -> kz_api:build_message(Req, ?RESPONSE_HEADERS, ?RESPONSE_OPT_HEADERS);
        'false' -> {'error', "Failed validate voxsquad response"}
    end.

response_v(Req) ->
    kz_api:validate(Req, ?RESPONSE_HEADERS, ?RESPONSE_VALUES, ?RESPONSE_TYPES).

-define(WEBHOOK_HEADERS, [<<"Call-ID">>, <<"Provider">>]).
-define(WEBHOOK_OPT_HEADERS, [<<"OpenAI-Leg-ID">>
                             ,<<"Webhook-ID">>
                             ,<<"Webhook-Timestamp">>
                             ,<<"Webhook-Signature">>
                             ,<<"Raw-Body">>
                             ]).
-define(WEBHOOK_VALUES, [{<<"Event-Category">>, <<"voxsquad">>}
                        ,{<<"Event-Name">>, <<"webhook">>}
                        ]).
-define(WEBHOOK_TYPES, [{<<"Webhook-ID">>, fun is_binary/1}
                       ,{<<"Webhook-Timestamp">>, fun is_binary/1}
                       ,{<<"Webhook-Signature">>, fun is_binary/1}
                       ,{<<"Raw-Body">>, fun is_binary/1}
                       ]).

publish_webhook(Req) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Req, ?WEBHOOK_VALUES, fun webhook/1),
    CallId = kz_json:get_value(<<"Call-ID">>, Req),
    Provider = kz_json:get_value(<<"Provider">>, Req),
    Routing = ?WEBHOOK_ROUTING(Provider, CallId),
    kz_amqp_util:kapps_publish(Routing, Payload).

webhook(Req) ->
    case webhook_v(Req) of
        'true' -> kz_api:build_message(Req, ?WEBHOOK_HEADERS, ?WEBHOOK_OPT_HEADERS);
        'false' -> {'error', "Failed validate voxsquad webhook"}
    end.

webhook_v(Req) ->
    kz_api:validate(Req, ?WEBHOOK_HEADERS, ?WEBHOOK_VALUES, ?WEBHOOK_TYPES).
