-include("util_types.hrl"). %For uid().

-type steve_query() :: peers | clients | {cid, uid()}.
-type steve_compreq() :: [tuple()].

%%
%% THE FOLLOWING ARE MESSAGES FROM CLIENTS THAT NEED TO BE HANDLED BY STEVE.
%%

-record(capi_reqdef,{id = nil :: nil | uid(), cnt = nil :: nil | term() }).
-define(CAPI_REQDEF( ID ), #capi_reqdef{ id = ID }).

-record(capi_query,{type :: steve_query()}).
-define(CAPI_QRY( Type ), #capi_query{ type = Type }).

-record(capi_comp,{id :: string(), cnt :: steve_compreq(), needsock :: boolean()}).
-define(CAPI_COMP( Cnt, Sock ), #capi_comp{ cnt = Cnt, needsock = Sock }).

-type cmsg() :: #capi_reqdef{} | #capi_query{} | #capi_comp{}.

%%
%% THE FOLLOWING ARE RETURN MESSAGES COMING FROM STEVE.
%%

-define(CAPI_REQDEF( ID, Cnt ), #capi_reqdef{ id = ID, cnt = Cnt }).

-record(capi_comp_ret, {cid :: uid(), sock = nil :: integer() | nil}).
-define(CAPI_COMP_RET( CID ), #capi_comp_ret{ cid = CID } ).
-define(CAPI_COMP_RET( CID, Conn ), #capi_comp_ret{ cid = CID, sock = Conn }).

-record(capi_query_ret, { success :: boolean(), result :: term() }).
-define(CAPI_QRY_RET( Res ), #capi_query_ret{ success=true, result=Res }).
-define(CAPI_QRY_ERR( Res ), #capi_query_ret{ success=false, result=Res }).

-type cmsg_ret() :: #capi_reqdef{} | #capi_comp_ret{} | #capi_query_ret{}.
