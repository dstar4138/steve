%% Steve Connection Server
%%  Maintains connections via TCP to friends or clients and handles incoming 
%%  and outgoing message queues process groups. See steve_sup to see how the
%%  two instances of steve_conn are started.
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

%% API
-export([start_link/0,start_link/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, { port, group, mq, wsock }).
               

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ ?DEFAULT_GROUP, 
                                                       ?DEFAULT_MQ,
                                                       ?DEFAULT_PORT
                                                     ], []).

start_link( WorkGroup, MqModule, Port ) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ WorkGroup,
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
    ok = pg:create( Group ),
    {ok, WSock} = gen_tcp:listen(Port,[{active,true}]),
    {ok, #state{port=Port, group=Group, mq=MqMod, wsock=WSock}, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling call messages, currently unused.
%%--------------------------------------------------------------------
handle_call( Request, From, State) -> 
    ?DEBUG("Conn server should not be getting calls (~p, ~p): ~p~n",[Request, From, State]),
    {stop, badarg, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling cast messages, currently unused.
%%--------------------------------------------------------------------
handle_cast( Msg, State) ->
    ?DEBUG("Conn server should not be getting casts (~p): ~p~n",[Msg,State]),
    {stop,badarg,State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} 
%% @end
%%--------------------------------------------------------------------
handle_info({tcp, Sock, RawData}, State) ->
    create_mq( Sock, RawData, State ),
    {noreply, State};
handle_info(timeout, State=#state{wsock=WS}) ->
    {ok,_} = gen_tcp:accept(WS),
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
create_mq( Sock, RawData, #state{group=G,mq=Mq} ) ->
    ?DEBUG("Recieved raw data: ~p",[RawData]),
    {ok, Pid} = Mq:start_link( Sock ),
    link(Pid), pg:join(G,Pid),
    ok.

% Send a shutdown message to all message queues.
shutdown_mqs( #state{group=G} ) ->
    pg:send(G, shutdown).

% Using the state, shut down the opened socket before termination.
close_sock( #state{wsock=WS} ) ->
    gen_tcp:close( WS ).

