-type steve_query() :: peers | clients | {cid, string()}.
-type steve_compreq() :: [tuple()].

-record(capi_reqdef,{id = nil :: nil | string() }).
-define(CAPI_REQDEF( ID ), #capi_reqdef{ id = ID }).

-record(capi_query,{type :: steve_query()}).
-define(CAPI_QRY( Type ), #capi_query{ type = Type }).

-record(capi_comp,{cnt :: steve_compreq(), needsock :: boolean()}).
-define(CAPI_COMP( Cnt, Sock ), #capi_comp{ cnt = Cnt, needsock = Sock }).

-type cmsg() :: #capi_reqdef{} | #capi_query{} | #capi_comp{}.
