%% Steve State Server Message Handling
%%
%%  This module handles the message handling separate from the state 
%%  manipulation. This is to ease the flow of viewing the computation.
%%
%% @author Alexander Dean
-module(steve_state_msg).
-compile(export_all). %XXX: Remove after testing!

-include("debug.hrl").
-include("capi.hrl").
-include("papi.hrl").
-include("steve_obj.hrl").
-include("steve_state.hrl").

%% Messaging Options
-export([broadcast/1, forward/2]).
%% Message Handlers
-export([handle_query/2, handle_note/3, handle_papim/3]).

%% @doc Broadcast a message to ALL friends/peers. To limit who to not send to
%%   use the forward/2 function.
%% @end        
broadcast( Msg ) -> 
    Friends = steve_conn:check_mq_group( friends ),
    lists:foldl( fun ( Peer, _ ) -> Peer ! Msg end, ok, Friends ).

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



%% @doc Handle a query and respond.
handle_query( peers, _ )   -> {reply, ?CAPI_QRY_RET( steve_conn:get_friend_count() )};
handle_query( clients, _ ) -> {reply, ?CAPI_QRY_RET( steve_conn:get_client_count() )};
handle_query( {cid, CID}, #steve_state{db=DB} ) -> 
    {reply, ?CAPI_QRY_RET( steve_db:check_cid(DB, CID) )};
handle_query( _, _ ) -> {reply, ?CAPI_QRY_ERR( <<"Unknown Query">> )}.

%% @doc Handle a notification message and update state.
handle_note( "CompAccept", Cnt, #steve_state{waiting_acceptors=Waiters} = State )->
    CID = capi:uuid_decode( proplists:get_value(<<"cid">>,Cnt) ),
    FriendInfo = proplists:get_value(<<"friend">>,Cnt),
    case check_if_self( FriendInfo ) of
        true ->
            ?DEBUG("Accepted computation acknowledgement from self: ~p",[CID]), 
            steve_state:trigger_computation( CID, State ),
            update_cap_store( CID, State );
        false ->
            {CIDWaiters, _} = lists:partition(fun({C,_,_})->C==CID end, Waiters),
            (case lists:keysearch( FriendInfo, 2, CIDWaiters ) of
                false -> State;
                {value, {_, _, _FConn}} ->
                    State %TODO: Send computation to Friend.
             end)
    end;
handle_note( Type, Cnt, State ) ->
    ?DEBUG("UNKNOWN NOTE MESSAGE: ~p -> ~p",[Type, Cnt]), State.

check_if_self( FriendInfo ) ->
    Fid = papi:ci_fid( FriendInfo ),
    MyID = papi:ci_fid( steve_state:my_contact_info() ),
    Fid == MyID.

update_cap_store( CID, #steve_state{cap_store=Store} = State ) ->
    NewStore = case lists:keytake( CID, 1, Store ) of
                   {value, _, New} -> New;
                   false -> Store %TODO: This is an error, we shouldn't
                                  % NOT have the action list in the cap_store.
               end, 
    State#steve_state{cap_store=NewStore}.



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
proc_check( Friend, #papim{from=Fwd} = Msg, State ) ->
    MyID = papi:ci_fid( steve_state:my_contact_info() ),
    case state_db:lookup_mask(Fwd) of
        {FriendID, FwdID} -> % Its just a forward, so send it back.
            NewMsg = Msg#papim{from=FwdID},
            steve_conn:send( friends, FriendID, NewMsg );
        false -> % It's a new message, so handle it:
            Res = handle_papim_type( Msg, State ),

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
                   #steve_state{caps=Cap} = _State ) -> 
   ContactInfo = steve_state:my_contact_info(),
   case requests:match( Cap, Cnt ) of
       {ok, nomatch} -> % No match, so forward to all friends except sender.
           {forward, Msg};
       {ok, Act} -> % Capable, so send back ack. and save reqdef hash for ref
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
           steve_state:temp_save( {cap_req, Hash, Act} ),
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
            steve_state:temp_save( {waiting_acceptors, Req, Conn} )
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
build_rescast( ID, _State ) ->
   ContactInfo = steve_state:my_contact_info(),
   FID = papi:ci_fid( ContactInfo ), 
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
broadcast_resreq() ->
    MissingResults = steve_db:get_missing_result_list(),
    ReqMsg = #papim{ type=?PAPI_RESREQ, 
                     cnt= lists:map( fun steve_util:uuid_to_str/1, 
                                     MissingResults ) },
    broadcast( ReqMsg ).

%% @hidden
%% @doc Sends out a computation request to all connected friends, and also to
%%   ourselves for possible acceptance.
%% @end  
broadcast_compeq( CompID, Cnt ) ->
    ReqMsg = #papim{ type=?PAPI_COMPREQ, val=CompID, cnt=Cnt },
    broadcast( ReqMsg ).

