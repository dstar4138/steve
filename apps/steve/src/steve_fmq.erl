%% Friend Message Queue
%%  A Queue used by steve_conn to handle message forwarding and broadcasting to
%%  other friends. It also knows how to manipulate and handle messages meeting
%%  the api.
%%
%%  Ultimately this should be merged with Client Message Queue due to how
%%  similar their process is. We will push this Async socket server into 
%%  another application.
%% 
%% @author Alexander Dean
-module(steve_fmq).
-behaviour(gen_fsm).
-include("debug.hrl").
-include("steve_obj.hrl").

%% API
-export([start_link/0]).
-export([set_socket/3, send_to_friend/2]).
-export([get_conn_details/1]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

%% FSM's States:
-export([ 'WAIT_FOR_SOCKET'/2,
          'WAIT_FOR_DATA'/2 ]).

%% Internal FSM State.
-record(state, {
          sock,   % Listening socket.
          addr,   % Friend's address.
          port,   % Friend's port.
          friend  % Friend object for referencing.
    }).

%% Socket timeout.
-define( TIMEOUT, 120000 ).        % LATER: Abstract out of this module.
%% Default Group.
-define( FRIEND_GROUP, friends ).  % LATER: Abstract out of this module.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Gets the connection details from the finite state machine.
%%
%% @spec get_conn_details( pid() ) -> {IP, Port, ID, Status}.
%% @end
%%--------------------------------------------------------------------
get_conn_details( PID ) ->
    PID ! {get_conn_details, self()},
    receive Msg -> Msg end. 

%%--------------------------------------------------------------------
%% @doc Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this 
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc Set an instance of this Message Queue's socket. This should
%% only be called once, after the MQ is started up. The steve_fmq_sup
%% module will do this after starting it.
%%
%% @spec set_socket( Pid, FriendObj, Socket ) -> ok.
%% @end
%%--------------------------------------------------------------------
set_socket( Pid, FriendObj, Socket ) when is_pid( Pid ), is_port( Socket ) ->
    gen_fsm:send_event( Pid, {socket_ready, FriendObj, Socket}).

%%--------------------------------------------------------------------
%% @doc Each instance of the message queue is part of a group, this 
%% will broadcast the a send request to the group. Only the particular
%% Friend (specified by the friend record) will respond to the 
%% request.
%%
%% @spec send_to_friend( FriendObj, RawData ) -> ok.
%% @end
%%--------------------------------------------------------------------
send_to_friend( FriendObj, RawData ) ->
    pg:send( ?FRIEND_GROUP, {send, FriendObj, RawData} ).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new 
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag( trap_exit, true ), 
    {ok, 'WAIT_FOR_SOCKET', #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc There should be one instance of this function for each 
%% possible state name. Whenever a gen_fsm receives an event sent 
%% using gen_fsm:send_event/2, the instance of this function with the 
%% same name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------

%% Waiting for a socket from steve_conn. Should happen fairly quickly.
'WAIT_FOR_SOCKET'( {socket_ready, Fobj, Sock}, State ) when is_port( Sock ) ->
    inet:setopts( Sock, [{active, once}, {packet, 2}, binary]),
    {ok, {IP, Port}} = inet:peername(Sock),
    {next_state, 'WAIT_FOR_DATA', State#state{ sock=Sock, addr=IP, 
                                               port=Port, friend=Fobj}};
'WAIT_FOR_SOCKET'( Msg, State ) ->
    ?ERROR("steve_fmq:wait_for_sock","Bad event: ~p",[Msg]),
    {next_state, 'WAIT_FOR_SOCKET', State}.

%% Normal state for message queue. Only responds to internal send requests.
%% Any data coming from the socket is handled by handle_info/3.
'WAIT_FOR_DATA'( {send, FriendObj, Bin}, #state{sock = Sock, friend=F} = State ) ->
     case FriendObj of  % TODO: Alter the test to use a FID
        F -> gen_tcp:send( Sock, Bin );
        _ -> ignore
    end,        
    {next_state, 'WAIT_FOR_DATA', State, ?TIMEOUT};
'WAIT_FOR_DATA'( timeout, State) ->
    ?ERROR("Friend connection timeout - closing.",[]),
    {stop, normal, State};
'WAIT_FOR_DATA'( Msg, State ) ->
    ?ERROR("steve_fmq:wait_for_data", "Bad event: ~p", [Msg]),
    {next_state, 'WAIT_FOR_DATA', State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% @private
%% @doc Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event( Event, StateName, State) ->
    {stop, {StateName, undefined_event, Event}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {stop, Reason, NewState} 
%% @end
%%--------------------------------------------------------------------
handle_sync_event( Event, _From, StateName, State) ->
    {stop, {StateName, undefined_event, Event}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event (or a 
%% system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info( {tcp, S, RawData}, StateName, #state{sock=S} = State ) ->
    ?DEBUG("Got TCP data in MQ: ~p~nSending to PAPI for parsing.",[RawData]),
    inet:setopts( S, [{active, once}] ),
    case papi:parse( RawData ) of
        {ok, Msg} -> 
            ?DEBUG("MQ got valid msg back, PAPI parsed to: ~p",[Msg]),
            process( Msg , StateName,  State );
        {error, Err} ->
            ?DEBUG("MQ got invalid msg error from PAPI: ~p",[Err]),
            handle_error( Err, State ),
            {next_state, StateName, State, ?TIMEOUT}
    end;
handle_info( {tcp_closed, S}, _StateName, #state{sock=S, addr=A} = State ) ->
    ?DEBUG("Friend ~p has disconnected.", [A]),
    {stop, normal, State};
handle_info( {pg_message, _From, ?FRIEND_GROUP, GroupMsg}, StateName, 
             State = #state{sock=S, friend=F} ) ->
    case GroupMsg of
        {shutdown, F} -> %TODO: Need a better compare if F is a record.
            ?DEBUG("MQ got shutdown message.",[]),
            gen_tcp:close(S),
            {stop, normal, State};
        shutdown ->
            ?DEBUG("MQ got broadcasted shutdown message.", []),
            gen_tcp:close(S),
            {stop, normal, State};
        {send, Cid, Data} ->
            ?DEBUG("Sending data to client (~p): ~p", [Cid, Data]),
            ok = gen_tcp:send( S, Data ),
            {next_state, StateName, State, ?TIMEOUT};
        _ -> % Unknown message
            ?DEBUG("Unknown Group message, ignoring: ~p",[GroupMsg]),
            {next_state, StateName, State, ?TIMEOUT}
    end;
handle_info( {get_conn_details, From}, StateName,
             #state{addr=IP, port=Port, friend=F} = State ) ->
    ID = get_friends_id( F ),
    From ! {IP, Port, ID, StateName},
    {next_state, StateName, State, ?TIMEOUT};
handle_info( Msg, StateName, State ) -> 
    ?DEBUG("Unknown Message to MQ: ~p",[Msg]),
    {next_state, StateName, State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% @private
%% @doc This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. 
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) -> ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @hidden
%% @doc Send an error as a message back over the wire.
handle_error( Err, _State = #state{sock=S} ) -> 
    gen_tcp:send( S, steve_util:encode_json([{<<"error">>,Err}]) ).

%% @hidden
%% @doc Send message to state server for processing, wait for reply and either
%% forward over wire or ignore.
%% @end
process( Msg , NextState, State = #state{sock=S}) ->
    ?DEBUG("Processing PAPI Message in State server: ~p", [Msg]),
    case steve_state:process_fmsg( Msg ) of
        {reply, Rep} -> 
            ?DEBUG("State server says to reply with: ~p",[Rep]),
            gen_tcp:send( S, papi:encode(Rep) ),
            {next_state, NextState, State};            
        noreply ->
            ?DEBUG("State server says not to reply.", []),
            {next_state, NextState, State};
        {shutdown, Reason} -> 
            ?DEBUG("State server says for MQ to shutdown with reason: ~p",[Reason]),
            {stop, Reason, State}
    end.

get_friends_id( #friend{ name=Name, id=ID } ) -> <<Name,ID/binary>>;
get_friends_id( ID ) -> ID.
