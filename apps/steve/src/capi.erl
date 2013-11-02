%% Client API Parser
%% 
%%  Reads in raw data and converts it to a CAPI message. Currently
%%  assumes there is no need to read in more than one packet to 
%%  complete a message (this is a big TODO).
%%
%% @author Alexander Dean
-module(capi).

% CAPI message types.
-include("capi.hrl").
-include("debug.hrl").

-export([parse/1]).
-export([encode/1]).

%% @doc Parses a RawData packet from a TCP socket, and converts it to a CAPI 
%% message record.
%% @end
-spec parse( binary() ) -> {ok, cmsg()} | {error, Reason :: atom() }.
parse( RawData ) ->
    case steve_util:decode_json( RawData ) of
       % Possible reasons: big_num, invalid_string, invalid_json, trailing_data
       {error, Reason, _} -> {error,Reason};
        Val -> decode(Val)
    end.

%% @doc Encodes a CAPI message (from server) into a binary string that can be
%% sent back to Client.
%% @end
-spec encode( cmsg_ret() ) -> binary().
encode( #capi_reqdef{ id=ID, cnt=Cnt } ) -> 
    steve_util:encode_json( [{<<"msg">>,<<"reqdef">>},
                             {<<"id">>,ID},
                             {<<"cnt">>,Cnt}] );
encode( #capi_comp_ret{ cid=CID, sock=Conn } ) ->
    Port = 
        if Conn == nil -> [];
           true -> [{<<"port">>,Conn}]
        end,
    steve_util:encode_json( [{<<"msg">>,<<"comp">>},
                             {<<"cid">>,CID} | Port ] );
encode( #capi_query_ret{ success=Success, result = Res } ) ->
    Msg = case Success of
                true -> <<"qr">>;
                false -> <<"qe">>
          end,
    steve_util:encode_json( [{<<"msg">>, Msg},{<<"cnt">>,Res}] ).

%% ===========================================================================
%% Internal Functions
%% ===========================================================================

%% @hidden
%% @doc Converts a json-proplist into a capi erlang record. See capi.hrl for
%% record definitions.
%% @end
decode( PList ) ->
    case gv(<<"msg">>, PList ) of
        <<"reqdef">> -> 
            {ok, ?CAPI_REQDEF( gv( <<"id">>, PList ) )};
        <<"qry">> -> 
            (case gv(<<"cnt">>, PList) of
                    nil -> {error, invalid_msg};
                    Other -> build_qry( Other )
             end);
        <<"comp">> -> 
            (case gv(<<"cnt">>, PList) of
                    nil -> {error, invalid_msg};
                    Other -> build_comp( Other, gvb( <<"needsock">>, PList) )
             end);
        _ -> {error, invalid_msg}
    end.

%% @hidden
%% @doc Get proplist key, used in decode/1.
gv( Key, List ) -> proplists:get_val( Key, List, nil ).
gvb( Key, List ) -> proplists:get_val( Key, List, false ).

%% @hidden
%% @doc Builds a Query message, or returns invalid_msg error if it's not a 
%% known query type.
%% @end
build_qry( <<"peers">> ) -> {ok, ?CAPI_QRY( peers )};
build_qry( <<"clients">> ) -> {ok, ?CAPI_QRY( clients )};
build_qry( [{ <<"cid">>, CID}] ) -> {ok, ?CAPI_QRY( {cid, CID} )};
build_qry( Unknown ) ->
    ?DEBUG("Unknown Query: ~p~n",[Unknown]),
    {error, invalid_msg}.

%% @hidden
%% @doc Builds a computation request message, or returns invalid_msg if
%% content is not a prop-list.
%% @end
build_comp( Cnt, Sock ) when is_list( Cnt ) -> {ok, ?CAPI_COMP( Cnt, Sock ) };
build_comp( Cnt, _ ) -> 
    ?DEBUG("Bad Comp Request, 'cnt' must be proplist: ~p~n",[Cnt]),
    {error, invalid_msg}.
