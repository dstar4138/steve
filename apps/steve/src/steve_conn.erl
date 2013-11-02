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
-define(SOCK_OPTS,[binary, {packet,2}, {reuseaddr,true}, {keepalive, true}, 
                   {backlog, 30}, {active,false}]).

%% API
-export([start_link/0,start_link/3]).
-export([get_friend_count/0, get_client_count/0, check_mq_group/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, { port, group, mq, wsock, ref, mqs }).
          

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Gets the number of currently connected Peers/Friends.
-spec get_friend_count() -> non_neg_integer().
get_friend_count() -> length( check_mq_group( friends ) ).

%% @doc Gets the number of currently connected Clients.
-spec get_client_count() -> non_neg_integer().
get_client_count() -> length( check_mq_group( clients ) ).


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
handle_call( Request, From, State) -> 
    ?DEBUG("Conn server should not be getting calls (~p, ~p): ~p",[Request, From, State]),
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
        case prim_inet:async_accept(ListSock, -1) of
            {ok,    NewRef} -> ok;
            {error, NewRef} -> exit({async_accept, inet:format_error(NewRef)})
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
    {noreply, State=#state{ mqs=NewMQs }};

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
