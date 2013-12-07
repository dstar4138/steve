%% Client Message Queue
%%   Follows the CAPI for communicating using JSON over TCP with a client. The
%%   message queue is being used to hold messages until a client reconnects.
%%
%%  Ultimately this should be merged with Client Message Queue due to how
%%  similar their process is. We will push this Async socket server into 
%%  another application.
%%
%% @author Alexander Dean
-module(steve_cmq).
-behaviour(gen_fsm).
-include("debug.hrl").

%% API
-export([start_link/0]).
-export([set_socket/3, send_to_client/2]).
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
            sock, % Listening socket.
            addr, % Client's address
            port, % Client's port
            cliID % Client ID for internal reference.
         }).

%% Socket timeout.
-define( TIMEOUT, 120000 ).       %LATER: Abstract out of this module.
%% Default Group.
-define( CLIENT_GROUP, clients ). %LATER: Abstract out of this module.

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
%% only be called once, after the MQ is started up. The steve_cmq_sup
%% module will do this after starting it.
%%
%% @spec set_socket( Pid, CliID, Socket ) -> ok.
%% @end
%%--------------------------------------------------------------------
set_socket( Pid, CliID, Socket ) when is_pid(Pid), is_port(Socket) ->
    gen_fsm:send_event(Pid, {socket_ready, CliID, Socket}).


%%--------------------------------------------------------------------
%% @doc Each instance of the message queue is part of a group, this 
%% will broadcast the a send request to the group. Only the particular
%% client (specified by the client ID) will respond to the request.
%%
%% @spec send_to_client( CliID, RawData ) -> ok.
%% @end
%%--------------------------------------------------------------------
send_to_client( CliID, RawData ) ->
    pg:send( ?CLIENT_GROUP, {send, CliID, RawData} ).

%%%===================================================================
%%% gen_fsm callbacks
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
    process_flag(trap_exit, true),
    ?DEBUG("MQ startup success.",[]),
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
'WAIT_FOR_SOCKET'( {socket_ready, CID, Sock}, State ) when is_port( Sock ) ->
    ?DEBUG("Recieved socket and Client ID in MQ.",[]),
    inet:setopts( Sock, [{active, once},{packet,line}, binary]),
    ?DEBUG("Successfully set socket options.",[]),
    {ok, {IP, Port}} = inet:peername(Sock),
    ?DEBUG("Successfully extracted foreign peer for reference",[]),
    {next_state, 'WAIT_FOR_DATA', State#state{ sock=Sock, addr=IP, 
                                               port=Port, cliID=CID}};
'WAIT_FOR_SOCKET'( Msg, State ) ->
    ?ERROR("steve_cmq:wait_for_sock","Bad event: ~p",[Msg]),
    {next_state, 'WAIT_FOR_SOCKET', State}.

%% Normal state for message queue. Only responds to internal send requests.
%% Any data coming from the socket is handled by handle_info/3.
'WAIT_FOR_DATA'( {send, CliID, Bin}, #state{sock = Sock, cliID=C} = State ) ->
    case CliID of % Only send if our Client ID matches, otherwise discard.
        C -> send( Sock, Bin );
        _ -> ignore
    end,        
    {next_state, 'WAIT_FOR_DATA', State, ?TIMEOUT};
'WAIT_FOR_DATA'( timeout, State) ->
    ?ERROR("Client connection timeout - closing.",[]),
    {stop, normal, State};
'WAIT_FOR_DATA'( Msg, State ) ->
    ?ERROR("steve_cmq:wait_for_data", "Bad event: ~p", [Msg]),
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
    ?DEBUG("Got TCP data in MQ: ~p~nSending to CAPI for parsing.",[RawData]),
    inet:setopts( S, [{active, once}] ),
    case capi:parse( RawData ) of
        {ok, Msg} -> 
            ?DEBUG("MQ got valid msg back, CAPI parsed to: ~p",[Msg]),
            process( Msg , StateName,  State );
        {error, Err} ->
            ?DEBUG("MQ got invalid msg error from CAPI: ~p",[Err]),
            handle_error( Err, State ),
            {next_state, StateName, State, ?TIMEOUT}
    end;
handle_info( {tcp_closed, S}, _StateName, #state{sock=S, addr=A} = State ) ->
    ?DEBUG("Client ~p is disconnected.", [A]),
    {stop, normal, State};
handle_info( {pg_message, _From, ?CLIENT_GROUP, GroupMsg}, StateName, 
             State = #state{sock=S, cliID=Cid} ) ->
    case GroupMsg of
        {shutdown, Cid} ->
            ?DEBUG("MQ got shutdown message.",[]),
            gen_tcp:close(S),
            {stop, normal, State};
        shutdown ->
            ?DEBUG("MQ got broadcasted shutdown message.", []),
            gen_tcp:close(S),
            {stop, normal, State};
        {send, Cid, Data} ->
            ?DEBUG("Sending data to client (~p): ~p", [Cid, Data]),
            ok = send( S, Data ),
            {next_state, StateName, State, ?TIMEOUT};
        {fwd, Excludes, Data} ->
            send_after_check( Excludes, Data, State ),
            {next_state, StateName, State, ?TIMEOUT};
        {note, Note} ->
            send_note( S, Note ),
            {next_state, StateName, State, ?TIMEOUT};
        _ -> % Unknown message
            ?DEBUG("Unknown Group message, ignoring: ~p",[GroupMsg]),
            {next_state, StateName, State, ?TIMEOUT}
    end;
handle_info( {get_conn_details, From}, StateName, 
             #state{addr=IP, port=Port, cliID=ID} = State ) ->
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
    send( S, steve_util:encode_json([{<<"error">>,Err}]) ).

%% @hidden
%% @doc Send message to state server for processing, wait for reply and either
%% forward over wire or ignore.
%% @end
process( Msg , NextState, State = #state{sock=S}) ->
    ?DEBUG("Processing CAPI Message in State server: ~p", [Msg]),
    case steve_state:process_cmsg( Msg ) of
        {reply, Rep} -> 
            RepEnc = capi:encode( Rep ),
            ?DEBUG("State server says to reply with: ~p",[RepEnc]),
            send( S, RepEnc ),
            {next_state, NextState, State};            
        noreply ->
            ?DEBUG("State server says not to reply.", []),
            {next_state, NextState, State};
        {shutdown, Reason} -> 
            ?DEBUG("State server says for MQ to shutdown with reason: ~p",[Reason]),
            {stop, Reason, State}
    end.

%% @hidden
%% @doc Converts the note to a binary message before sending it off. 
send_note( S, Note ) -> send( S, capi:encode( Note ) ).

%% @hidden
%% @doc Since we are using {packet,line} based sockets we need to wrap all 
%%  send calls with an appendage of a new line.
%% @end
send( S, << BMsg/binary>> ) -> gen_tcp:send(S, <<BMsg/binary, $\n>>).

%% @hidden
%% @doc Checks if the current Client ID is in the excludes list before sending.
send_after_check( Excludes, Data, #state{sock=S, cliID=ID} = _State ) ->
    case lists:member( ID, Excludes ) of
        true -> ok;
        false -> 
            Encoded = capi:encode( Data ),
            send( S, Encoded )
    end.

