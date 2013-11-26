%% Peer API Parser
%%
%%  Reads in raw data and converts it to a PAPI message. Currently assumes
%%  there is no need to read in more than one packet to complete a message
%%  (this is a big TODO).
%%
%% @author Alexander Dean
-module(papi).

% PAPI message types.
-include("papi.hrl").
-include("debug.hrl").

-export([parse/1]).
-export([encode/1]).

% Message keys
-define(M,<<$m>>).
-define(C,<<$c>>).
-define(V,<<$v>>).
-define(F,<<$f>>).

%% @doc Parses a RawData packet from a TCP socket, and converts it to a CAPI 
%% message record.
%% @end
-spec parse( binary() ) -> {ok, fmsg()} | {error, Reason :: atom() }.
parse( RawData ) ->
    case steve_util:decode_json( RawData ) of
       % Possible reasons: big_num, invalid_string, invalid_json, trailing_data
       {error, Reason, _} -> {error,Reason};
        Val -> decode(Val)
    end.

%% @doc Encodes a PAPI message (from server) into a binary string that can be
%% sent back to a Peer.
%% @end
-spec encode( fmsg() ) -> binary().
encode( #papim{from=F, type=T, cnt=C, val=V} ) -> 
    PropList = 
        encode_from(F, encode_type(T, encode_cnt(C, encode_val( V, [])))),
    steve_util:encode_json( PropList ).

encode_from( nil, Acc ) -> Acc;
encode_from( Code, Acc ) when is_binary( Code ) ->
    [{?F,uuid_encode( Code )}|Acc].
encode_type( T, Acc ) when is_integer( T ) -> [{?M,T}|Acc].
encode_cnt( nil, Acc ) -> Acc;
encode_cnt( C, Acc ) -> [{?C,C}|Acc].
encode_val( nil, Acc )-> Acc;
encode_val( V, Acc ) -> [{?V,V}|Acc].
      


%% ===========================================================================
%% Internal Functions
%% ===========================================================================

%% @hidden
%% @doc Encodes a UUID value for sending out.
uuid_encode( ID ) -> 
    erlang:list_to_binary( steve_util:uuid_to_str( ID ) ).


%% @hidden
%% @doc Decodes a Proplist into a papi record. See papi.hrl for record 
%%  definitions.
%% @end
decode( PList ) -> 
    M = gv( ?M, PList ),
    F = gv( ?F, PList ),
    C = gv( ?C, PList ),
    V = gv( ?V, PList ),
    {ok, #papim{ from=F, type=M, cnt=C, val=V }}.


%% @hidden
%% @doc Get proplist key, used in decode/1.
gv( Key, List ) -> proplists:get_value( Key, List, nil ).

