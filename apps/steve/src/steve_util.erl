%% Utility Functions used throughout Steve.
%% @author Alexander Dean
-module(steve_util).
-include("steve.hrl").
-include("debug.hrl").
-include("util_types.hrl").

% We want a proplist back rather than a stuct or eep18.
-define(JSONX_OPTIONS, [{format,proplist}]).

-export([uuid/0, valid_uuid/1]).
-export([hash/1]).
-export([loadrc/1, readfile/1, clean_path/1]).
-export([encode_json/1, decode_json/1]).
-export([getrootdir/0]).

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


%% @doc Use the JSONx Library for decoding a binary Json message.
-spec decode_json( binary() ) -> term().
decode_json( Binary ) -> jsonx:decode( Binary, ?JSONX_OPTIONS ).


%% @doc Use the JSONx Library for encoding a binary Json message.
-spec encode_json( term() ) -> binary().
encode_json( Term ) -> jsonx:encode( Term ).


%% @doc Interpret a RC file by reading it in and evaluating it.
-spec loadrc( string() ) -> {ok, [term()]} | {error, Reason :: atom()}.
loadrc( FilePath ) ->
    file:consult( clean_path( FilePath ) ).


%% @doc Reads in a file and returns the contents as a binary string. It
%% will first check the path to make sure it exists. (It will also expand
%% the '~' to be the system home directory.) The return signature is that
%% of file:read_file/1.
%% @end
-spec readfile( string() ) -> {ok, binary()} | {error, Reason :: atom() }.
readfile( FilePath ) ->
    file:read_file( clean_path( FilePath ) ).


%% @doc Clean a file path for the local OS.
-spec clean_path( string() ) -> string().
clean_path( Path ) -> filename:nativename( tilde_expand( Path ) ).

%% @doc Get the root directory Steve uses for saving/config
getrootdir() ->
    case application:get_env(steve, rootdir) of
        undefined -> ?DEFAULT_STEVEDIR;
        {ok, P} -> P
    end.

%% ===========================================================================
%% Private Functions
%% ===========================================================================

%% @hidden
%% @doc Checks for a '~' character at the beginning and replaces with home url.
-spec tilde_expand( string() ) -> string().
tilde_expand( [ $~ | RestOfPath ] ) -> 
    {ok, [[Home]]} = init:get_argument(home), %TODO: check on non-linux os
    string:concat( Home, RestOfPath );
tilde_expand( Path ) -> Path.

