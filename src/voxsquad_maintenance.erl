-module(voxsquad_maintenance).

-export([refresh_schemas/0]).

-include("voxsquad.hrl").

-spec refresh_schemas() -> 'ok'.
refresh_schemas() ->
    kz_datamgr:revise_docs_from_folder(?KZ_SCHEMA_DB, ?APP, <<"schemas">>).
