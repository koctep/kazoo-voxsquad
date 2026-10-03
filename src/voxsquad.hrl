-ifndef(VOXSQUAD_HRL).

%% Typical includes needed
-include_lib("kazoo_stdlib/include/kz_types.hrl").
-include_lib("kazoo_stdlib/include/kz_log.hrl").
-include_lib("kazoo_stdlib/include/kz_databases.hrl").

-define(APP, 'voxsquad').
-define(APP_NAME, <<"voxsquad">>).
-define(APP_VERSION, kz_util:application_version(?APP)).

-define(SHARED_NAME, ?APP_NAME).

-define(GPROC_NAME(Name), {'n', 'l', Name}).

-define(VOXSQUAD_HRL, true).
-endif.
