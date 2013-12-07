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
-export([process_cmsg/1, process_fmsg/2]).
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

%%%===================================================================
%%% API
%%%===================================================================

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
init( StartArgs ) ->
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
handle_call({cmsg, #capi_reqdef{id=Id}}, _From, State) ->
    Cid = case Id of nil -> steve_util:uuid(); _ -> Id end,
    ReqDef = State#steve_state.reqs,
    {reply, {reply,?CAPI_REQDEF( Cid, ReqDef )}, State}; 

handle_call({cmsg, #capi_comp{id=Id, needsock=Files, cnt=Cnt}}, _From, 
            #steve_state{out_req=Outs} = State ) ->
    MyId = papi:ci_fid( my_contact_info() ),
    CID = steve_util:uuid(), % Generate new Computation ID.
    steve_state_msg:broadcast_compeq( MyId, CID, Cnt ), % Broadcast client has new comp-request
    NewState = State#steve_state{out_req=[{CID,Id}|Outs]},
    if Files -> % If Client has files to send over, open a connection and inform
            case steve_ftp:get_conn_port() of
                {error, Reason} ->
                   ?ERROR("steve_state:handle_call",Reason,[]),
                    {reply, {reply,?CAPI_COMP_RET( CID)}, NewState};
                Conn -> 
                    {reply, {reply,?CAPI_COMP_RET( CID, Conn )}, NewState}
            end;
        true ->
            {reply, {reply, ?CAPI_COMP_RET( CID )}, NewState}
    end;

handle_call({cmsg, #capi_query{type=Qry}}, _From, State) ->
    ClientReply = steve_state_msg:handle_query( Qry, State ), 
    {reply, ClientReply, State };

handle_call({cmsg, #capi_note{type=Note,cnt=Cnt}}, _From, State) ->
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
handle_cast( {notify_client, OfThing}, 
             #steve_state{out_req=Outs, waiting_acceptors=Waits} = State ) ->
    NewState =  
        case OfThing of
            {compack, FriendInfo, CID, FriendConn} ->
                ClientID = proplists:get_value( CID, Outs ), 
                Note = tonote({compack, FriendInfo, CID}),
                steve_cmq:send_to_client( ClientID, {note, Note} ),
                State#steve_state{ waiting_acceptors=
                                      [{CID, FriendInfo, FriendConn}|Waits] };
            _ -> State
        end,
    {noreply, NewState};
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

update_state( {{waiting_acceptors, Req, Conn}, FriendInfo}, _State ) ->
    gen_server:cast( ?MODULE, {notify_client, {compack, FriendInfo, Req, Conn}} );
update_state( {cap_req, Hash, Cap}, #steve_state{ cap_store=C } = State ) ->
    State#steve_state{ cap_store=[{Hash,Cap}|C] };
update_state( Unknown, State ) ->
    ?DEBUG("Unknown state update message: ~p",[Unknown]),
    State.

%% @hidden
%% @doc Convert the note to its object type.
tonote({compack, FriendInfo, CID}) ->
    ?CAPI_NOTE( "CompAck", [{<<"friend">>,FriendInfo},{<<"cid">>,CID}] );
tonote( _ ) -> nil.

