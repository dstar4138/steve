-type papi_msg_code() :: 0|1|2|3|4|5|6|7.

-define(PAPI_COMPREQ,0). % Request for computation.
-define(PAPI_COMPACK,1). % Acknowledgement of capability.
-define(PAPI_RESCAST,2). % Broadcast computation result.
-define(PAPI_RESREQ, 3). % Request for particular computation result.
-define(PAPI_REPCHK, 4). % Reputation check.
-define(PAPI_REPACK, 5). % Reputation acknowledgement.
-define(PAPI_FRNDREQ,6). % Friend Request.
-define(PAPI_FRNDACK,7). % Friend acknowledgement.

% The content of a PAPI message depends on the message type.
-type papi_cnt() :: nil | binary() | term().

% The value is nil for all messages besides RESCAST amd REPACK.
-type papi_val() :: nil | boolean().

% The Internal message representation.
-record(papim, {
          type      :: papi_msg_code(), 
          cnt = nil :: papi_cnt(),
          val = nil :: papi_val()
}).

% Message constructors.
-define(PAPI_COMPREQ(REQDEF),   #papim{ type=?PAPI_COMPREQ, cnt=REQDEF }).
-define(PAPI_COMPACK(CID),      #papim{ type=?PAPI_COMPACK, cnt=CID }).
-define(PAPI_RESCAST(CID, Val), #papim{ tyoe=?PAPI_RESCAST, cnt=CID, val=Val }).
-define(PAPI_RESREQ(CIDs),      #papim{ type=?PAPI_RESREQ, cnt=CIDs }).
-define(PAPI_REPCHK(CID),       #papim{ type=?PAPI_REPCHK, cnt=CID }).
-define(PAPI_REPACK(CID, Rep),  #papim{ type=?PAPI_REPACK, cnt=CID, val=Rep }).
-define(PAPI_FRNDREQ(CIDs),     #papim{ type=?PAPI_FRNDREQ, cnt=CIDs }).
-define(PAPI_FRNDACK(Peers),    #papim{ type=?PAPI_FRNDACK, cnt=Peers }).

-type fmsg() :: #papim{}.
