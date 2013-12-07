%% Steve state server
%%   Handles core of Steve's logical flow.
%%
%% @author Alexander Dean
-module(steve_state).
-behaviour(gen_server).
-compile(export_all). %XXX: Remove after testing!

-include("debug.hrl").
-include("steve_obj.hrl").
-include("capi.hrl").
-include("papi.hrl").

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

-record(steve_state, {  id, contact,
                        reqs, caps, db,
                        % Temporary State maintained:
                        cap_store = [], % ReqHash -> Capability Action store.
                        out_req   = [], % ReqHash -> Outstanding Requests.
                        waiting_acceptors = [] % ReqHash -> Friendnfo, FriendConn 
                        }).

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
    check_for_updates(),
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
            #steve_state{id=MyId, out_req=Outs} = State ) ->
    CID = steve_util:uuid(), % Generate new Computation ID.
    broadcast_compeq( MyId, CID, Cnt ), % Broadcast client has new comp-request
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
    {reply, run_query( Qry, State ), State };

handle_call({fmsg, Friend, Msg}, _From, State) ->
    handle_papim( Friend, Msg, State ),
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
parse_args( [], State) -> 
    ContactInfo = my_contact_info(),
    FID = papi:ci_fid(ContactInfo),
    State#steve_state{id=FID,contact=ContactInfo}; 
parse_args( [{rcfile, Cnt}|Rest], State ) ->
    {[Requests,CapList],_} = proplists:split(Cnt, [requests, capability]),
    RequestStruct = hd(Requests), %LATER: warn user that only the first is considered.
    {ok, CapStruct} = requests:build(RequestStruct, CapList),
    JsonStyleReqStruct = capi:gen_req_def( RequestStruct ),
    NewState = State#steve_state{reqs=JsonStyleReqStruct, caps=CapStruct},
    parse_args( Rest, NewState );
parse_args( [_|R], S ) -> parse_args(R,S). %TODO: Any other Args?

%%% Messaging Handlers

%% @hidden
%% @doc Broadcast a message to ALL friends/peers. To limit who to not send to
%%   use the forward/2 function.
%% @end        
broadcast( Msg ) -> 
    Friends = steve_conn:check_mq_group( friends ),
    lists:foldl( fun ( Peer, _ ) -> Peer ! Msg end, ok, Friends ).

%% @hidden
%% @doc Similar to broadcast, but will forward to all friends/peers except the 
%%   excluded friend. This is for requests that we can't personally fill.
%% @end  
forward( ExcludedFriend, Msg ) ->
    OldFwdID = Msg#papim.from, 
    OldHops = Msg#papim.hops,
    case OldHops of
        0 -> ok; % Not allowed to hop further. Max number of hops so DISCARD.
        _ -> 
            NewFwdID = steve_db:save_and_mask_msg( OldFwdID, ExcludedFriend ),
            NewMsg = Msg#papim{ from = NewFwdID, hops=OldHops-1 },
            steve_conn:esend( friends, NewMsg, [ExcludedFriend] )
    end.

%% @hidden
%% @doc Handle a query and respond.
run_query( peers, _ )   -> {reply, ?CAPI_QRY_RET( steve_conn:get_friend_count() )};
run_query( clients, _ ) -> {reply, ?CAPI_QRY_RET( steve_conn:get_client_count() )};
run_query( {cid, CID}, #steve_state{db=DB} ) -> 
    {reply, ?CAPI_QRY_RET( steve_db:check_cid(DB, CID) )};
run_query( _, _ ) -> {reply, ?CAPI_QRY_ERR( <<"Unknown Query">> )}.

%% @hidden
%% @doc Convert the note to its object type.
tonote({compack, FriendInfo, CID}) ->
    ?CAPI_NOTE( "CompAck", [{<<"friend">>,FriendInfo},{<<"cid">>,CID}] );
tonote( _ ) -> nil.


%% @hidden
%% @doc Checks if the message is a repeat and discards if yes, otherwise it will
%%   verify it's not a forwarded message coming back. If it was, then we should
%%   forward it back to the person in our forward table. If its a normal message
%%   process it.
%% @end
handle_papim( Friend, Msg, State ) ->
    MsgHash = steve_util:hash( Msg ),
    case steve_db:check_mark_seen( MsgHash ) of
        true -> ok; % We already saw this message. DISCARD.
        false -> % New message, lookup if this is a reply to a forwarded message
            spawn(?MODULE, proc_check, [Friend, Msg, State])
    end.

%% @hidden
%% @doc If the message is forwarded, handle sending it back, otherwise process.
proc_check( Friend, #papim{from=Fwd} = Msg, #steve_state{id=MyID} = State ) ->
    case state_db:lookup_mask(Fwd) of
        {FriendID, FwdID} -> % Its just a forward, so send it back.
            NewMsg = Msg#papim{from=FwdID},
            steve_conn:send( friends, FriendID, NewMsg );
        false -> % It's a new message, so handle it:
            Res = case handle_papim_type( Msg, State) of
                {update, Update, Reply} -> 
                    update_state( {Update, Friend}, State ),
                    Reply;
                Reply -> Reply
            end,

            % If we are who sent the message, that means it came on
            % loopback. We would have therefore already have broadcasted
            % or forwarded. We can safely ignore the result of processing.
            if Friend == MyID -> pass; 
               is_list( Res ) ->
                   lists:map(fun(M)->process_msg(M,Friend) end, Res);
               true -> process_msg(Res, Friend)
            end
    end.
process_msg( Res, Friend ) ->
    case Res of
        noreply -> ok;
        {reply, Value} -> steve_conn:send( friends, Friend, Value );
        {broadcast, Value} -> broadcast( Value );
        {forward, Value} -> forward( Friend, Value )
     end.


%% @hidden
%% @doc Run the handling logic per type of message it is.
handle_papim_type( #papim{type=?PAPI_COMPREQ, cnt=Cnt} = Msg, 
                   #steve_state{contact=ContactInfo, caps=Cap} = _State ) -> 
   case requests:match( Cap, Cnt ) of
       {ok, nomatch} -> % No match, so forward to all friends except sender.
           {forward, Msg};
       {ok, Cap} -> % Capable, so send back ack. and save reqdef hash for ref
           Hash = Msg#papim.val,
           NewAck = #papim{ from=Msg#papim.from,
                            type=?PAPI_COMPACK,
                            cnt=Hash, %TODO: copy/pastes supposed HASH, 
                                      % we should really calculate it 
                                      % ourselves and send. The real
                                      % sender will know it's for them,
                                      % don't want someone disabling
                                      % someone's requesting ability
                                      % by substituting hashes.      
                            val=ContactInfo
                          },
           steve_state:temp_save( {cap_req, Hash, Cap} ),
           {reply, NewAck};
       {error, badcaps} -> 
           ?ERROR("steve_state:handle_papim",
                  "Found Bad capability when trying to match: ~p", [Cnt]),
           noreply
    end;
handle_papim_type( #papim{type=?PAPI_COMPACK, 
                          from=nil,  % Only even look up if we own the request.
                          cnt=Hash,val=Conn}, 
                   #steve_state{ out_req=Outs } ) ->
    case lists:keysearch( Hash, 1, Outs ) of
        false -> noreply; % Discard, we don't remember request.
        {Hash, Req} ->  %Push computation passing to new proc and send noreply
            {update, {waiting_acceptors, Req, Conn}, noreply}
    end;
handle_papim_type( #papim{type=?PAPI_RESCAST, cnt=Hash, val=ResReport} = Msg, 
                   _State ) -> 
    %   Check if we have the result stored,
    %   if yes, then discard.
    %   otherwise, save and perpetuate broadcast.
    case steve_db:check_result( Hash, ResReport ) of
        true -> % We have the result, so ignore.
            noreply;
        false -> % We did not have the result, so start a process to get it
                 % and forward the broadcast on.
            steve_state:start_result_grab( ResReport ),
            {broadcast, Msg}
    end;
handle_papim_type( #papim{type=?PAPI_RESREQ, cnt=IDs} = Msg, 
                   State ) ->
    %   Check if we have the results stored,
    %   if yes, then send peer directly a RESCAST message for each ID
    %   otherwise,
    %       if we've heard of ID before, perpetuate RESREQ message onward
    %       otherwise, discard.
    {Done, Missing} = steve_state:check_result_state( IDs ),
    F = fun(D) -> case steve_state:build_rescast(D, State) of
                      {error, _Reason} -> noreply;
                      {ok, Comp} -> {reply, Comp}
                  end 
         end,
    Replys = lists:map( F, Done ),
    Fwd = case Missing of 
        [] -> [];
        _  ->[{forward, Msg#papim{cnt=Missing}}]
    end,
    Fwd++Replys; % Sends back a list of messages.
handle_papim_type( #papim{type=?PAPI_REPCHK}, _State ) -> 
    %TODO: If we have a reputation for this individual, send back REPACK.
    %   Otherwise we replace from field with self and save maping and broadcast
    %       to others. 
    ok;
handle_papim_type( #papim{type=?PAPI_REPACK}, _State ) -> 
    %TODO: Did we send the REPCHK?
    %   if yes, then augment our rep with the new rep ack
    %   otherwise, wrap with our rep
    ok;
handle_papim_type( #papim{type=?PAPI_FRNDREQ}, _State ) -> 
    %TODO: Grab top half of peers based on reputation and filter by
    %   Cnt, which is a list of already known peers. Fwd FRNDREQ to them.
    %   Send FRNDACK if you are not on the ignore list. If there are any 
    %   unrecognized values in Cnt List, we may want to send a Frndreq
    %   of our own if we are in a starved state
    ok;
handle_papim_type( #papim{type=?PAPI_FRNDACK}, _State ) -> 
    %%TODO: Did we send a FRNDREQ?
    %%  if yes, then potentially add FRND to peer's list. 
    ok.

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

ask_friends_help( _ConnData, _Request ) ->
    %   Update db with new handler. If new friend, connect and 
    %       start transfer for archive.
    %   otherwise, forward it on to the peer that send the req through you.
    ok. %TODO: implement sending connection request to new friend, or computation to friend.

start_result_grab( _ResReport ) -> 
    % TODO: Spawn a process to start copying data from FID to local store,
    %  then update the db with hash of archive.
    ok.

%% @hidden
%% @doc Loops over the list of IDs from a Result Request, and checks if
%%   we have the result for that particular computation. WARNING: This has
%%   the potential for taking a LONG time.
%% @end
check_result_state( L ) -> check_result_state( L, [], [] ).
check_result_state( [], Done, Missing ) -> {Done, Missing};
check_result_state( [H|R], Done, Missing ) ->
    case steve_db:has_handler_result(H) of
        true -> check_result_state( R, [H|Done], Missing );
        false -> check_result_state( R, Done, [H|Missing] )
    end.

%% @hidden
%% @doc Creates a Result Cast message using just the ID of the result. It looks
%%   up all data from the database.
%% @end
build_rescast( ID, #steve_state{id=FID,contact=ContactInfo} = _State ) -> 
   case steve_db:get_comp( ID ) of 
       {error, Reason} -> {error, Reason};
       C -> 
           ResultReport = papi:create_rr( ContactInfo, 
                                          C#computation.value,
                                          C#computation.has_archive ),
           #papim{from=FID, type=?PAPI_RESCAST, cnt=ID, val=ResultReport}
    end.

%% @hidden
%% @doc The other half of the function above, this will check the local system
%%    upon startup and broadcast to all connected friends that we are missing
%%    some results.
%% @end
check_for_updates() ->
    MissingResults = steve_db:get_missing_result_list(),
    ReqMsg = #papim{ type=?PAPI_RESREQ, 
                     cnt= lists:map( fun steve_util:uuid_to_str/1, 
                                     MissingResults ) },
    broadcast( ReqMsg ).

%% @hidden
%% @doc Sends out a computation request to all connected friends, and also to
%%   ourselves for possible acceptance.
%% @end  
broadcast_compeq( NodeId, CompID, Cnt ) ->
    ReqMsg = #papim{ type=?PAPI_COMPREQ, val=CompID, cnt=Cnt },
    broadcast( ReqMsg ),
    process_fmsg( NodeId, ReqMsg ). % Send fmsg to self, making sure we know its us

