-include("requests.hrl").

%% Reputation of a friend is right now just an integer, but in theory it could
%% represent something much more elaborate such as a list of past offences or 
%% tracking information.
-type 'REPUTATION'() :: integer().

%% A Friend is a socket wrapped with some information about who is on the other
%% end. We read these objects in on load-time and manipulate them only when 
%% their reputation changes or their last-known address.
%% @see steve_friend.erl
-record( friend, { 
        % Unique ID that friend gave you.
        id   :: binary(), %UUID()
        % Human readable name, set locally.
        name :: binary(),
        % The local reputation of this friend.
        rep  :: 'REPUTATION'(),
        % Last known location of friend.
        addr :: inet:ip_address() | inet:hostname(),
        % Socket process that can handle your Message to send.
        sock :: pid() | null
        } ).
-type 'FRIEND'() :: #friend{}.
-define(FRIEND(ID,Name,Rep,Addr), #friend{id=ID,name=Name,rep=Rep,addr=Addr}).

%% A computation is a reference to a piece of code on the local machine along 
%% with some boilerplate information about it. It is used to serialize it so it
%% can be sent over the wire.
-record( computation, {
        % This is the name of the computation, which could be different.
        id                         :: binary(), %UUID()
        % Short name of the computation, it is the hash of the computation's
        % data blob.
        hash = nil                 :: integer(), %HASH()
        has_archive = false        :: boolean(),
        % The request object, if we have it yet. If not, then it needs to 
        % be written.
        req                        :: 'REQUEST'() 
        % Has at least one friend told us it's finished.
        finished = false           :: boolean(),
        % Do we have the results saved locally?
        has_result_locally = false :: boolean(),
        % Which Friends are working on it?
        friends_computing = [] :: [ binary() ] %[ UUID() ]
        } ).
-type 'COMPUTATION'() :: #computation{}.
-define(COMPUTATION(Id,Archive,Hash,Req), 
        #computation{id=Id,has_archive=Archive,hash=Hash,req=Req}).
-define(COMPUTATION(Id,Archive,Hash,Req,Finished,HasRes,Computers),
        #computation{id=Id,has_archive=Archive,hash=Hash,req=Req,
                     finished=Finished,
                     hash_result_locally=HasRes,
                     friends_computing=Computers}).
