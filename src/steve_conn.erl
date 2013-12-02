%% Steve Connection Server
%%  Maintains connections via TCP to friends or clients and handles incoming 
%%  and outgoing message queues process groups. See steve_sup to see how the
%%  two instances of steve_conn are started.
%%
%%  This uses the async method demo'ed by Serge Aleynikov at erlangcentral.org.
%%  See steve_cmq_sup and steve_cmq for the other portions of the async socket
%%  implementation.
%%
%% @author Alexander Dean
%%
-module(steve_conn).
-behaviour(gen_server).
-include("debug.hrl").

% Name of the thread pool used for broadcasting.
-define(DEFAULT_GROUP, clients).
% Default message queue implementation.
-define(DEFAULT_MQ, steve_cmq).
% A default ephemeral port
-define(DEFAULT_PORT, 50505).
% The name of the gen_server process made by using Group.
-define(MOD( G ), erlang:list_to_atom( erlang:atom_to_list( G ) ++ "_serve" )).
% The socket options for the Welcome Socket.
-define(SOCK_OPTS,[binary, {packet,line}, {reuseaddr,true}, {keepalive, true}, 
                   {backlog, 30}, {active,false}]).

%% API
-export([start_link/0,start_link/3]).
-export([get_friend_count/0, get_client_count/0, check_mq_group/1]).
-export([get_friend_list/0, get_client_list/0]).
-export([esend/3, send/3]).
-export([friend_conn_info/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, { port, group, mq, wsock, ref, mqs=[] }).
          

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Ask the running friends conn server what the connection details are.
-spec friend_conn_info() -> tuple(). %TODO: better define type.
friend_conn_info() ->
    gen_server:call( ?MOD( friends ), get_conn ). 

%% @doc Send a message to a particular group member.
-spec send( atom(), any(), any() ) -> ok.
send( Group, Who, Msg ) -> pg:send( Group, {send, Who, Msg} ), ok.

%% @doc Send a message out to all message queues excluding the ones on the 
%%   Excludes list. We rely on the implementation of the Message Queue to 
%%   exclude itself.
%% @end
-spec esend( atom(), any(), [any()] ) -> ok.
esend( Group, Msg, Excludes ) -> pg:send( Group, {fwd, Excludes, Msg} ), ok.

%% @doc Gets the number of currently connected Peers/Friends.
-spec get_friend_count() -> non_neg_integer().
get_friend_count() -> length( check_mq_group( friends ) ).

%% @doc Gets the number of currently connected Clients.
-spec get_client_count() -> non_neg_integer().
get_client_count() -> length( check_mq_group( clients ) ).

%% @doc Gets a list of friend connections of the status: {IP,Port,ID,Status}.
-spec get_friend_list() -> [ tuple() ].
get_friend_list() ->
    lists:foldl( merge_conn(steve_fmq), [], check_mq_group(friends) ).

%% @doc Gets a list of friend connections of the status: {IP,Port,ID,Status}.
-spec get_client_list() -> [ tuple() ].
get_client_list() ->
    lists:foldl( merge_conn(steve_cmq), [], check_mq_group(clients) ).

%% @private
%% @doc Used for the get_*_list functions above to call a PID of a MQ and get 
%%   its connection status and details and merge it with an accumulated list
%%   so far. We drop bad connections.
%% @end
-spec merge_conn( atom() ) -> fun().
merge_conn( MQ ) ->
    fun( PID, Acc ) ->
        [erlang:apply( MQ, get_conn_details, [PID] )|Acc]
    end.
        
%% @doc Get a list of process id's of all message queues in a particular 
%% process group. There are only two groups, friends | clients. See 
%% steve_sup for more information.
%% @end
check_mq_group( Group ) ->
    case catch pg:members( Group ) of
        L when is_list(L) -> L;
        _ -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MOD(?DEFAULT_GROUP)}, ?MODULE, [ 
                                                       ?DEFAULT_GROUP, 
                                                       ?DEFAULT_MQ,
                                                       ?DEFAULT_PORT
                                                     ], []).

start_link( WorkGroup, MqModule, Port ) ->
    gen_server:start_link({local, ?MOD(WorkGroup)}, ?MODULE, [ 
                                                       WorkGroup,
                                                       MqModule,
                                                       Port
                                                     ], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) ->  {ok, State, Timeout}
%% @end
%%--------------------------------------------------------------------
init([Group, MqMod, Port]) ->
    process_flag(trap_exit, true),
    ok = create_group( Group ),
    case gen_tcp:listen( Port, ?SOCK_OPTS ) of
        {ok, WSock} ->
            % Create first accepting process.
            {ok, Ref} = prim_inet:async_accept( WSock, -1 ),
            {ok, #state{port=Port, group=Group, mq=MqMod, wsock=WSock, ref=Ref}};
        {error, Reason} ->
            {stop, Reason}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling call messages, currently unused.
%%--------------------------------------------------------------------
handle_call( get_conn, _From, #state{ port=Port } = State ) ->
    {ok, IP} = get_ip(),
    {reply, {IP, Port}, State};
handle_call( Request, From, State) -> 
    ?DEBUG("Conn server should not be getting calls (~p, ~p): ~p", 
           [Request, From, State]),
    {stop, badarg, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling cast messages, currently unused.
%%--------------------------------------------------------------------
handle_cast( Msg, State) ->
    ?DEBUG("Conn server should not be getting casts (~p): ~p",[Msg,State]),
    {stop, badarg, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} 
%% @end
%%--------------------------------------------------------------------
handle_info( {inet_async, ListSock, Ref, {ok, CliSocket}},
            #state{ wsock=WSock, ref=Ref, mqs=MQs } = State) ->
    try 
        case set_sockopt( WSock, CliSocket ) of
            ok -> ok;
            {error, Reason} -> exit({set_sockopt, Reason})
        end,

        %% New client connected - spawn a new process using the message queue
        %% implementation passed in on init.
        {ok, MQRef} = create_mq( CliSocket, State ),

        %% Signal the network driver that we are ready to accept another 
        %% connection.
        NewRef = case prim_inet:async_accept(ListSock, -1) of
            {ok,    NR} -> NR;
            {error, NR} -> 
                    exit({async_accept, inet:format_error(NR)}), 
                    NR
        end,
        {noreply, State#state{ref=NewRef, mqs=[MQRef|MQs]}}
    catch exit:Why ->
            ?ERROR("steve_conn:handle_info","Error in async accept conn: ~p.",[Why]),
            {stop, Why, State}
    end;
handle_info( {inet_async, _ListSock, _Ref, Error}, State ) ->
    ?ERROR("steve_conn:handle_info", "Error in socket acceptor: ~p.", [Error]),
    {stop, Error, State};
handle_info( {'EXIT', Pid, Status}, #state{mqs=MQs} = State ) ->
    ?ERROR("steve_conn:handle_info", "Message Queue crashed with message: ~p",[Status]),
    NewMQs = lists:keydelete( Pid, 1, MQs ),
    {noreply, State#state{ mqs=NewMQs }};

handle_info( Msg, State ) ->
    ?DEBUG("Conn server should not be getting misc msgs ( ~p ):~p",[Msg,State]),
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) -> shutdown_mqs( State ), close_sock( State ), ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

% Creates and links to a Friend Message Queue in a particular work group.
create_mq( Sock, #state{group=G,mq=Mq} ) ->
    MQID = steve_util:uuid(), % Generate new ID to reference the MQ with
    {ok, Pid} = Mq:start_mq( G, MQID, Sock ), 
    link( Pid ),
    {ok, {Pid, MQID}}.

% Send a shutdown message to all message queues.
shutdown_mqs( #state{group=G} ) ->
    pg:send(G, shutdown).

% Using the state, shut down the opened socket before termination.
close_sock( #state{wsock=WS} ) ->
    gen_tcp:close( WS ).

% Creates a group, if it already exists, we can hijack
create_group( Group ) ->
    case pg:create( Group ) of
        ok -> ok;
        {error, already_created} -> ok;
        Err -> Err
    end.

%% Taken from prim_init. We are merely copying some socket options from the 
%% listening socket to the new client socket.
set_sockopt( ListSock, CliSocket ) ->
    true = inet_db:register_socket( CliSocket, inet_tcp ),
    case prim_inet:getopts( ListSock, 
                [active, nodelay, keepalive, delay_send, priority, tos] ) 
    of
        {ok, Opts} ->
            case prim_inet:setopts(CliSocket, Opts) of
                ok -> ok;
                Error -> gen_tcp:close(CliSocket), Error
            end;
        Error -> gen_tcp:close(CliSocket), Error
    end.

%% @hidden
%% @doc Get the IP of the local daemon instance. For this daemon to communicate
%%   outside of a private network, it's 'global_ip' configuration option will 
%%   need to be overridden in the configuration file. Otherwise it will just
%%   grab the local IP given to it by the router.
%% @end
get_ip() ->
    Check = case application:get_env( steve, global_ip ) of
        {ok, IPString} -> 
            (case inet:parse_address( IPString ) of
                 {ok, _} -> {ok, IPString};
                 _ -> error
             end);
        undefined -> error
    end,
    case Check of
        error -> 
            {ok, IPs} = inet:getif(),
            IP = element( 1, hd(IPs) ),
            IPS = io_lib:format( "~w.~w.~w.~w", tuple_to_list(IP) ),
            {ok, lists:flatten(IPS)};
        _ -> {ok, "127.0.0.1"} % Default return localhost.
    end.
 
