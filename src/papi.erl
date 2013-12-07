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
-include("util_types.hrl").
-include("debug.hrl").

-export([parse/1]).
-export([encode/1]).

-type result_report() :: [ tuple() ].
-export([create_rr/3]).
-export([rr_fid/1, rr_archived/1, rr_value/1]).
-export_type([result_report/0]).

-type contact_info() :: [ tuple() ].
-export([create_ci/3]).
-export([ci_ip/1,ci_port/1,ci_fid/1]).
-export_type([contact_info/0]).

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
%% The Following are accessor methods for various "values" of the papi message
%% structure.
%%      - Result Reports
%%      - Contact Information

-spec create_rr( contact_info(), any(), boolean() ) -> result_report().
create_rr( ContactInfo, Value, Archived ) ->
   [{<<"ci">>,ContactInfo}, {<<"val">>,Value}, {<<"hasarchive">>,Archived}].

%% @doc Result Report accessor for the Friend's ID.
-spec rr_fid( result_report() ) -> nil | uid().
rr_fid( R ) -> ci_fid( rr_ci( R ) ).

%% @doc Result Report accessor for the Contact Info of the broadcasting 
%%   individual.
%% @end   
-spec rr_ci( result_report() ) -> contact_info().
rr_ci( R ) -> proplist:get_value( <<"ci">>, R, [] ).

%% @doc Result Report accessor for whether the result has an archive.
-spec rr_archived( result_report() ) -> boolean().
rr_archived( R ) -> proplist:get_value( <<"hasarchive">>, R, false ).

%% @doc Result Report access for the value of the result. Note if there 
%%  is no value, then most likely it's in an archive.
%% @end
-spec rr_value( result_report() ) -> any().
rr_value( R ) -> proplist:get_value( <<"val">>, R, nil ). 


%% @doc Create a Contact Information dictionary for placing into a PAPI message.
-spec create_ci( string(), integer(), uid() ) -> contact_info().
create_ci( IP, Port, UID ) -> 
    ID = uuid_encode( UID ),
    [{<<"ip">>, IP}, {<<"port">>, Port}, {<<"fid">>, ID}].

% @doc Contact Info dictionary lookup for IP.
-spec ci_ip( contact_info() ) -> string().
ci_ip( C ) -> proplist:get_value( <<"ip">>, C, "127.0.0.1" ).

% @doc Contact Info dictionary lookup for port.
-spec ci_port( contact_info() ) -> integer().
ci_port( C ) -> proplist:get_value( <<"port">>, C, 50505 ).

% @doc Contact Info dictionary lookup for the Friend's ID.
-spec ci_fid( contact_info() ) -> nil | uid().
ci_fid( C ) -> prop_uuid( <<"fid">>, C ).


%% ===========================================================================
%% Internal Functions
%% ===========================================================================

%% @hidden
%% @doc Easy extraction of UUID's from 
prop_uuid( IDName, PropList ) ->
    case proplists:get_value( IDName, PropList, nil ) of
        nil -> nil;
        ID -> uuid_decode( ID )
    end.

%% @hidden
%% @doc Encodes a UUID value for sending out.
uuid_encode( Nil ) when is_atom( Nil ) -> null;
uuid_encode( ID ) -> 
    erlang:list_to_binary( steve_util:uuid_to_str( ID ) ).

%% @hidden
%% @doc Decodes a UUID value for bringing into Steve.
uuid_decode( Nil ) when is_atom( Nil ) -> nil;
uuid_decode( ID ) ->
    steve_util:str_to_uuid( erlang:binary_to_list( ID ) ).

%% @hidden
%% @doc Decodes a Proplist into a papi record. See papi.hrl for record 
%%  definitions.
%% @end
decode( PList ) -> 
    M = wn(gv( ?M, PList )),
    F = wn(gv( ?F, PList )),
    C = wn(gv( ?C, PList )),
    V = wn(gv( ?V, PList )),
    {ok, #papim{ from=F, type=M, cnt=C, val=V }}.


%% @hidden
%% @doc Get proplist key, used in decode/1.
gv( Key, List ) -> proplists:get_value( Key, List, nil ).
wn( null ) -> nil;
wn( Data ) -> Data.
