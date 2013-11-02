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
-spec encode( fmsg_ret() ) -> binary().
encode( Msg ) -> <<"null">>.


%% ===========================================================================
%%
%% ===========================================================================

decode( PList ) -> ok.
