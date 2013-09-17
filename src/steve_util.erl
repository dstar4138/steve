%% Utility Functions used throughout Steve.
%% @author Alexander Dean
-module(steve_util).
-include("debug.hrl").
-include("util_types.hrl").

-export([uuid/0, valid_uuid/1]).
-export([hash/1]).


%% @doc Follows RFC4122 for generating UUIDs version 4 via Random Numbers. 
%% This function will perform fairly slowly as it uses the crypto module,
%% as apposed to hand running rand:uniform/1. But I feel this is more readable
%% and we don't actually call uuid/0 frequently. 
%% @end
-spec uuid() -> uid().
uuid()->
    <<A:48,B:12,C:62,_:6>>=crypto:rand_bytes(16),
    <<A:48,4:4,B:12,2:2,C:62>>.


%% @doc Checks to make sure the uuid is of the right size and is version 4.
-spec valid_uuid( uid() ) -> boolean().
valid_uuid( UID ) when is_binary( UID ) ->
    case UID of
        <<_:48,4:4,_:12,2:2,_:62>> -> true;
        _ -> false
    end.

%% @doc Hashes using the erlang's built in portable hashing function. We 
%% introduce the arbitrary requirement that the parameter is binary so we 
%% don't hash a record.
%% @end
-spec hash( binary() ) -> hash().
hash( Blob ) when is_binary( Blob ) -> erlang:phash2( Blob ).

