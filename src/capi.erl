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

-export([uuid_encode/1]).
-export([gen_req_def/1, ref_def_map/1]).

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
                             {<<"id">>,uuid_encode( ID )},
                             {<<"cnt">>,Cnt}] );
encode( #capi_comp_ret{ cid=CID, sock=Conn } ) ->
    Port = 
        if Conn == nil -> [];
           true -> [{<<"port">>,Conn}]
        end,
    steve_util:encode_json( [{<<"msg">>,<<"comp">>},
                             {<<"cid">>,uuid_encode(CID)} | Port ] );
encode( #capi_query_ret{ success=Success, result = Res } ) ->
    Msg = case Success of
                true -> <<"qr">>;
                false -> <<"qe">>
          end,
    steve_util:encode_json( [{<<"msg">>, Msg},{<<"cnt">>,Res}] );
encode( #capi_note{ type=T, cnt=Cnt } ) ->
    Msg = [{ <<"msg">>,<<"note">>},
           { <<"type">>,b(T)},
           {<<"cnt">>, Cnt}],
    steve_util:encode_json( Msg ). 

%% ===========================================================================
%% Internal Functions
%% ===========================================================================

%% @hidden
%% @doc Encodes a UUID value for sending out.
uuid_encode( ID ) -> erlang:list_to_binary( steve_util:uuid_to_str( ID ) ).

%% @hidden
%% @doc Decodes a UUID value for bringing into Steve.
uuid_decode( Nil ) when is_atom( Nil ) -> nil;
uuid_decode( ID ) ->
    steve_util:str_to_uuid( erlang:binary_to_list( ID ) ).

%% @hidden
%% @doc Converts a json-proplist into a capi erlang record. See capi.hrl for
%% record definitions.
%% @end
decode( PList ) ->
    case gv(<<"msg">>, PList ) of
        <<"reqdef">> ->
            ID = try uuid_decode( gv(<<"id">>,PList) )
                 catch _:_ -> nil end,
            {ok, ?CAPI_REQDEF( ID )};
        <<"qry">> -> 
            (case gv(<<"cnt">>, PList) of
                    nil -> {error, invalid_msg};
                    Other -> build_qry( Other )
             end);
        <<"comp">> -> 
            (case gv(<<"cnt">>, PList) of
                    nil -> {error, invalid_msg};
                    Other -> 
                        build_comp( uuid_decode( gv(<<"id">>, PList) ),
                                    Other, 
                                    gvb( <<"needsock">>, PList) )
             end);
        _ -> {error, invalid_msg}
    end.

%% @hidden
%% @doc Get proplist key, used in decode/1.
gv( Key, List ) -> proplists:get_value( Key, List, nil ).
gvb( Key, List ) -> proplists:get_value( Key, List, false ).

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
build_comp( ID, Cnt, Sock ) when is_list( Cnt ) -> {ok, ?CAPI_COMP( ID, Cnt, Sock ) };
build_comp( _, Cnt, _ ) -> 
    ?DEBUG("Bad Comp Request, 'cnt' must be proplist: ~p~n",[Cnt]),
    {error, invalid_msg}.


%%% ==========================================================================
%%% Exclusive steve_state API
%%% ==========================================================================

%% @hidden
%% @doc Generates a json compatible reqstruct for sending to clients.
gen_req_def( {requests, ReqStrctList} ) -> gen_req_def( ReqStrctList, [] ).
gen_req_def( [], A ) -> A;
gen_req_def( [{Name,required,Value}|Rest], A ) ->
    Dat = [ {<<"name">>, b(Name)},
            {<<"required">>, true},
            {<<"val">>, gen_req_def_val( Value )} ],
    gen_req_def( Rest, [Dat|A] );
gen_req_def( [{Name, Value}|Rest], A ) ->
    Dat =  [ {<<"name">>, b(Name)},
             {<<"required">>, false},
             {<<"val">>, gen_req_def_val( Value )} ],
    gen_req_def( Rest, [Dat|A] ).
gen_req_def_val( Key )     when is_atom(Key) -> [{<<"key">>, b( Key )}];
gen_req_def_val( Binary )  when is_binary( Binary ) -> Binary;
gen_req_def_val( Tuple )   when is_tuple( Tuple ) ->
    lists:map( fun({Name,Val}) -> { b(Name), gen_req_def_val( Val )} end,
               erlang:tuple_to_list( Tuple ) );
gen_req_def_val( List=[H|_] )   when is_list( List ) ->
    case is_list(H) orelse is_tuple(H) orelse is_binary(H) of
        true -> % Then its a list of values
            lists:map( fun gen_req_def_val/1, List );
        false -> % Then its a string
            b( List )
    end.

%% @hidden
%% @doc Convert a value to binary.
b( N ) when is_binary( N ) -> N;
b( N ) when is_list( N ) -> erlang:list_to_binary( N );
b( N ) when is_atom( N ) -> erlang:atom_to_binary( N, unicode ).

%% @hidden
%% @doc Converts the json compatible reqstruct back into a map we can
%%   use when matching.
%% @end  
ref_def_map( LDict ) -> {request, ref_def_map( LDict, [] )}.
ref_def_map([], Acc) -> Acc;
ref_def_map([Map|R], Acc) -> ref_def_map( R, [gen_map_reqdef( Map )|Acc] ).
gen_map_reqdef(Map) ->
    Name = proplists:get_value(<<"name">>,Map),
    Value = proplists:get_value(<<"val">>,Map),
    try
        BName = erlang:binary_to_existing_atom(Name,latin1),
        LValue = erlang:bitstring_to_list( Value ),
        {BName, LValue}
    catch _:_ -> {Name,Value} end.

