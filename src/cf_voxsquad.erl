%%%-----------------------------------------------------------------------------
%%%-----------------------------------------------------------------------------
-module(cf_voxsquad).

-export([handle/2]).

-include_lib("callflow/src/callflow.hrl").

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec handle(kz_json:object(), kapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    Provider = kz_json:get_value(<<"provider">>, Data),
    Config = kz_json:get_value(Provider, Data),
    lager:info("voxsquad callflow started for provider ~p", [Provider]),
    KappsCall = kapps_call:to_json(Call),
    Req0 = kz_json:from_map(#{<<"Provider">> => Provider
                             ,<<"Config">> => Config
                             ,<<"Call">> => KappsCall
                             }),
    Req = kz_json:set_values(kz_api:default_headers(?APP_NAME, ?APP_VERSION), Req0),
    {'ok', _Response} = kz_amqp_worker:call(Req
                                           ,fun kapi_voxsquad:publish_request/1
                                           ,fun kapi_voxsquad:response_v/1
                                           ,'infinity'),
    lager:debug("got response ~p", [_Response]),
    cf_exe:continue(Call).
