%% Steve state server
%%   Handles core of Steve's logical flow.
%%
%% @author Alexander Dean
-module(steve_state).
-behaviour(gen_server).
-compile(export_all).

-include("debug.hrl").
-include("steve_obj.hrl").
-include("capi.hrl").

%% API
-export([start_link/1]).
-export([process_cmsg/1]).
-export([peer_write_perm_check/2, 
         peer_read_perm_check/2,
         peer_file_event/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(steve_state, { reqs, caps, db }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Check if a Client/Friend is connected via MQ and if they have valid
%%      WRITE permission of a particular Computational ID. Used in the 
%%      steve_ftp callback module for file transfers.
%% @end
-spec peer_write_perm_check( tuple(), uid() ) -> boolean().
peer_write_perm_check( Peer, CompID ) -> true. %TODO: verify peer has access


%% @doc Check if a Client/Friend is connected via MQ and if they have valid
%%      READ permission of a particular Computational ID. Used in the 
%%      steve_ftp callback module for file transfers.
%% @end
-spec peer_read_perm_check( tuple(), uid() ) -> boolean().
peer_read_perm_check( Peer, CompID ) -> true. %TODO: verify peer has access

%% @doc If an event happens on a particular file, namely if its finished
%%  writing or reading, steve will most likely need to be informed.
%% @end
-spec peer_file_event( uid(), tuple() ) -> ok.
peer_file_event( CompID, Event ) ->
    ?DEBUG("Peer ~p file in repo: ~p",[Event, CompID]),
    ok.

%% @doc Ask the state server to process a client's message. This is called
%% from steve_cmq:process/2.
%% @end
process_cmsg( Msg ) -> gen_server:call( ?MODULE, {cmsg, Msg} ).

%% @doc Ask the state server to process a friend's message. This is called
%% from steve_fmq:process/2.
%% @end
process_fmsg( Msg ) -> gen_server:call( ?MODULE, {fmsg, Msg} ).


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link( StartArgs ) ->
     gen_server:start_link({local, ?MODULE}, ?MODULE, [StartArgs], []).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} 
%% @end
%%--------------------------------------------------------------------
init( StartArgs ) ->
    ?DEBUG("Got Args: ~p~n",[StartArgs]),
    process_flag(trap_exit, true),
    State = parse_args(StartArgs, #steve_state{}),
    broadcast( update ),
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({cmsg, #capi_reqdef{id=Id}}, _From, State) ->
    Cid = case Id of nil -> steve_util:uuid(); _ -> Id end,
    ReqDef = State#steve_state.reqs,
    {reply, {reply,?CAPI_REQDEF( Cid, ReqDef )}, State}; 

handle_call({cmsg, #capi_comp{id=Id, needsock=Files, cnt=Cnt}}, _From, State ) ->
    CID = steve_util:uuid(), % Generate new Computation ID.
    broadcast( {comp_req, Id, CID, Cnt} ), % Broadcast client has new comp-request
    if Files -> % If Client has files to send over, open a connection and inform
            {ok, Conn} = steve_ftp:start_conn( Id, CID ),
            {reply, {reply,?CAPI_COMP_RET( CID, Conn )}, State};
        true ->
            {reply, {reply, ?CAPI_COMP_RET( CID )}, State}
    end;
handle_call({cmsg, #capi_query{type=Qry}}, _From, State) ->
    {reply, run_query( Qry, State ), State };


handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling all non call/cast messages. Unused.
%%--------------------------------------------------------------------
handle_info(_Info, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) -> ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Convert process state when code is changed. Unused.
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @hidden
%% @doc Parses the incoming arguments.
parse_args( [], State) -> State;
parse_args( [{rcfile, Cnt}|Rest], State ) ->
    {[Requests,CapList],_} = proplists:split(Cnt, [requests, capability]),
    RequestStruct = hd(Requests), %LATER: warn user that only the first is considered.
    {ok, CapStruct} = requests:build(RequestStruct, CapList),
    JsonStyleReqStruct = gen_req_def( RequestStruct ),
    NewState = State#steve_state{reqs=JsonStyleReqStruct, caps=CapStruct},
    parse_args( Rest, NewState );
parse_args( [_|R], S ) -> parse_args(R,S). %TODO: Any other Args?

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


%%% Messaging Handlers

%% @hidden
%% @doc Broadcast a message to all friends/peers.
broadcast( update ) -> ok; %TODO: Actually push message to steve_conn
broadcast( {comp_req, ID, CID, Cnt} ) -> ok.

%% @hidden
%% @doc Handle a query and respond.
run_query( peers, _ )   -> {reply, ?CAPI_QRY_RET( steve_conn:get_friend_count() )};
run_query( clients, _ ) -> {reply, ?CAPI_QRY_RET( steve_conn:get_client_count() )};
run_query( {cid, CID}, #steve_state{db=DB} ) -> 
    {reply, ?CAPI_QRY_RET( steve_db:check_cid(DB, CID) )};
run_query( _, _ ) -> {reply, ?CAPI_QRY_ERR( <<"Unknown Query">> )}.

