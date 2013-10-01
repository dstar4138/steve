-include("util_types.hrl").
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
        id   :: uid(),
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

%% A computation is a reference to a piece of code on the local machine along 
%% with some boilerplate information about it. It is used to serialize it so it
%% can be sent over the wire.
-record( computation, {
        % Short name of the computation, it is the hash of the computation's
        % data blob.
        name :: hash(),
        % The request object, if we have it yet. If not, then it needs to 
        % be written.
        req  :: 'REQUEST'() | null,
        % Data blob, if read in or recieved from the wire.
        blob :: binary() | null,
        % Location on local machine.
        loc  :: binary() | null
        } ).
-type 'COMPUTATION'() :: #computation{}.

