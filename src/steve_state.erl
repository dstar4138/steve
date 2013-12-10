%% Steve state server
%%   Handles core of Steve's logical flow.
%%
%% @author Alexander Dean
-module(steve_state).
-behaviour(gen_server).
-compile(export_all). %XXX: Remove after testing!

-include("debug.hrl").
-include("capi.hrl").
-include("papi.hrl").
-include("steve_state.hrl").

%% API
-export([start_link/1]).
-export([process_cmsg/2, process_fmsg/2]).
-export([peer_write_perm_check/2,peer_perm_check/3, 
         peer_read_perm_check/2,
         peer_file_event/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%%===================================================================
%%% API
%%%===================================================================


computation_alert( finished, CompID ) ->
    gen_server:cast( ?MODULE, {compalert, CompID, finished} ).

peer_perm_check(_,_,_) -> true.

%% @doc Check if a Client/Friend is connected via MQ and if they have valid
%%      WRITE permission of a particular Computational ID. Used in the 
%%      steve_ftp callback module for file transfers.
%% @end
-spec peer_write_perm_check( tuple(), uid() ) -> boolean().
peer_write_perm_check( _Peer, _CompID ) -> true. %TODO: verify peer has access


%% @doc Check if a Client/Friend is connected via MQ and if they have valid
%%      READ permission of a particular Computational ID. Used in the 
%%      steve_ftp callback module for file transfers.
%% @end
-spec peer_read_perm_check( tuple(), uid() ) -> boolean().
peer_read_perm_check( _Peer, _CompID ) -> true. %TODO: verify peer has access

%% @doc If an event happens on a particular file, namely if its finished
%%  writing or reading, steve will most likely need to be informed.
%%  Like if a computation is waiting for it to finish.
%% @end
-spec peer_file_event( uid(), tuple() ) -> ok.
peer_file_event( CompID, Event ) ->
    ?DEBUG("Peer ~p file in repo: ~p",[Event, CompID]),
    case Event of
        {finish_write, _, _} -> 
            steve_comp_sup:archive_upload_finished( CompID );
        _ -> ok %Intentional ignore of finish_read. PAPI not finished.
    end.

%% @doc Ask the state server to process a client's message. This is called
%% from steve_cmq:process/2.
%% @end
process_cmsg( CliID, Msg ) -> gen_server:call( ?MODULE, {cmsg, CliID, Msg} ).

%% @doc Ask the state server to process a friend's message. This is called
%% from steve_fmq:process/2.
%% @end
process_fmsg( F, Msg ) -> gen_server:call( ?MODULE, {fmsg, F, Msg} ).

%% @hidden
%% @doc Internal cast to ask for a state save update. Comes typically from a 
%%   separate process handling a PAPI message.
%% @end
-spec temp_save( any() ) -> ok.
temp_save( Msg ) ->
    gen_server:cast( ?MODULE, {temp_save, Msg} ).


ask_friends_help( _ConnData, _Request ) ->
    %   Update db with new handler. If new friend, connect and 
    %       start transfer for archive.
    %   otherwise, forward it on to the peer that send the req through you.
    ok. %TODO: implement sending connection request to new friend, or computation to friend.

start_result_grab( _ResReport ) -> 
    % TODO: Spawn a process to start copying data from FID to local store,
    %  then update the db with hash of archive.
    ok.

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
%% @doc Initializes the server
%%--------------------------------------------------------------------
-spec init( list() ) -> {ok, #steve_state{}}.
init( [StartArgs] ) ->
    ?DEBUG("Got Args: ~p~n",[StartArgs]),
    process_flag(trap_exit, true),
    State = parse_args(StartArgs, #steve_state{}),
    steve_state_msg:broadcast_resreq(),
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
handle_call({cmsg, Cid, #capi_reqdef{id=_Id}}, _From, State) ->
%    Cid = case Id of nil -> steve_util:uuid(); _ -> Id end,
    ReqDef = State#steve_state.reqs,
    {reply, {reply,?CAPI_REQDEF( Cid, ReqDef )}, State}; 

handle_call({cmsg, Id, #capi_comp{ needsock=Files, cnt=Cnt}}, _From, 
            #steve_state{out_req=Outs} = State ) ->
    CID = steve_util:uuid(),                      % Generate new Computation ID.
    steve_state_msg:broadcast_compeq( CID, Cnt ), % Broadcast new CompReq msg.
    check_local_caplist( Files, Id, CID, Cnt, State ), % Check local capability.
    Reply =
        if Files -> % If Client has files to send over, open a connection and inform
             case steve_ftp:get_conn_port() of
                {error, Reason} ->
                   ?ERROR("steve_state:handle_call",Reason,[]),
                    {reply,?CAPI_COMP_RET( CID)};
                Conn -> {reply,?CAPI_COMP_RET( CID, Conn )}
             end;
           true -> {reply, ?CAPI_COMP_RET( CID )}
        end,
    NewState = State#steve_state{out_req=[{CID,Id}|Outs]},
    {reply, Reply, NewState};

handle_call({cmsg, _Id, #capi_query{type=Qry}}, _From, State) ->
    ClientReply = steve_state_msg:handle_query( Qry, State ), 
    {reply, ClientReply, State };

handle_call({cmsg, _Id, #capi_note{type=Note,cnt=Cnt}}, _From, State) ->
    NewState = steve_state_msg:handle_note( Note, Cnt, State ),
    {reply, noreply, NewState};

handle_call({fmsg, Friend, Msg}, _From, State) ->
    ok = steve_state_msg:handle_papim( Friend, Msg, State ),
    {reply, ok, State};

handle_call(_Request, _From, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handles casted messages from spawned processes.
%%--------------------------------------------------------------------
-spec handle_cast( any(), #steve_state{} ) -> {noreply, #steve_state{}}.
handle_cast( {compalert, CompID, Status}, State ) ->
    handle_compalert( CompID, Status, State ),
    {noreply, State};
handle_cast( {temp_save, Msg}, State ) ->
    NewState = update_state( Msg, State ),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling all non call/cast messages. Unused.
%%--------------------------------------------------------------------
-spec handle_info( any(), #steve_state{} ) -> {noreply, #steve_state{}}.
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
    JsonStyleReqStruct = capi:gen_req_def( RequestStruct ),
    NewState = State#steve_state{reqs=JsonStyleReqStruct, caps=CapStruct},
    parse_args( Rest, NewState );
parse_args( [_|R], S ) -> parse_args(R,S). %TODO: Any other Args?

%% @hidden
%% @doc Gets the contact information for the current system.
my_contact_info( ) ->
    {IP, Port} = steve_conn:friend_conn_info(),
    BIP = list_to_binary(IP),
    CID = case steve_db:get_state_key( my_id ) of
              {my_id, Bcid} -> Bcid;
              _ -> null %TODO: This is an error state. This is bad.
          end,
    %% The following must be valid JSON for message sending.
    papi:create_ci( BIP, Port, CID ).

%% @hidden
%% @doc See handle_cast/2, this will update the state based on a temp_save/1
%%   call. They are made by the PAPI handlers.
%% @end  
update_state( {waiting_acceptors, CID, FriendConn}, 
              #steve_state{out_req=Outs, waiting_acceptors=Waits} = State ) ->
    ClientID = proplists:get_value( CID, Outs ), 
    notify_client(ClientID, {compack, FriendConn, CID}),
    State#steve_state{ waiting_acceptors=[{CID, FriendConn}|Waits] };
update_state( {cap_req, Hash, Cap, F}, #steve_state{ cap_store=C } = State ) ->
    State#steve_state{ cap_store=[{Hash,Cap,F}|C] };
update_state( Unknown, State ) ->
    ?DEBUG("Unknown state update message: ~p",[Unknown]),
    State.

%% @hidden
%% @doc Checks local capability for a particular ComputationID, if it's 
%%   able to handle it, then we'll message the Client with a CompAck 
%%   notification.
%% @end  
check_local_caplist( HangForArchive, ClientId, CID, RawCnt, 
                     #steve_state{ caps=CapStruct } ) ->
   spawn( fun() -> 
        Request = capi:ref_def_map( RawCnt ),
        case requests:match( CapStruct, Request ) of
            {ok, nomatch} -> ok;
            {ok, Act} ->
                temp_save( {cap_req, CID, Act, HangForArchive } ),
                notify_client( ClientId, {compack, my_contact_info(), CID} );
            {error, badcaps} ->
                ?ERROR("steve_state:check_local_caplist",
                       "Found Bad Capability when trying to match ~p",[Request])
        end
    end).
%% @hidden
%% @doc Send a Notification to a client. Will construct the note message.
notify_client( ClientID, NoteMsg ) ->
    NoteObj = tonote( NoteMsg ),
    Msg = capi:encode( NoteObj ),
    steve_cmq:send_to_client( ClientID, Msg ).

%% @hidden
%% @doc Convert the note to its object type.
tonote({compack, FriendConn, CID}) ->
    FriendInfo = FriendConn, %TODO: Must update Conn Structure with reputation and name.
    BCID = capi:uuid_encode( CID ),
    ?CAPI_NOTE( "CompAck", [{<<"friend">>,FriendInfo},{<<"cid">>,BCID}] );
tonote( _ ) -> nil.


%% @hidden
%% @doc called from steve_state_msg:handle_note(CompAccept).
trigger_computation( CID, #steve_state{cap_store=Store} = _State ) ->
    case lists:keyfind( CID, 1, Store ) of
        {_, ActionList, WaitForArchive} -> 
            steve_comp_sup:start_computation( CID, ActionList, WaitForArchive );
        false -> 
            ?ERROR("steve_state:trigger_computation",
                   "Attempting to trigger a computation we didn't accept: ~p",
                   [CID])
    end.


handle_compalert( CompID, finished, _State ) ->
    BCID = capi:uuid_encode(CompID),
    Data = capi:encode(?CAPI_QRY_RET( [{<<"cid">>,BCID}] )),
    pg:send(clients,{send, Data});

handle_compalert( _,_,_ ) -> ok.
