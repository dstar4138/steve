%% Client Message Queue
%%   Follows the CAPI for communicating using JSON over TCP with a client. The
%%   message queue is being used to hold messages until a client reconnects.
%%
%% @author Alexander Dean
-module(steve_cmq).
-behaviour(gen_server).
-include("debug.hrl").

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
                sock, % Listening socket.
                cid   % Client ID for internal reference.
               }).

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
start_link( Socket ) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Socket], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Socket]) ->
    {ok, #state{sock=Socket}}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling call messages, currently unused.
%%--------------------------------------------------------------------
handle_call( Request, From, State) -> 
    ?DEBUG("MQ should not be getting calls (~p, ~p): ~p",[Request, From, State]),
    {stop, badarg, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling cast messages, currently unused.
%%--------------------------------------------------------------------
handle_cast( Msg, State) ->
    ?DEBUG("MQ should not be getting casts (~p): ~p",[Msg,State]),
    {stop, badarg, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({tcp, _Socket, RawData}, State ) ->
    ?DEBUG("Got TCP data in MQ: ~p~nSending to CAPI for parsing.",[RawData]),
    case capi:parse( RawData ) of
        {ok, Msg} -> 
            ?DEBUG("MQ got valid msg back, CAPI parsed to: ~p",[Msg]),
            process( Msg , State );
        {error, Err} ->
            ?DEBUG("MQ got invalid msg error from CAPI: ~p",[Err]),
            handle_error( Err, State ),
            {noreply, State}
    end;
handle_info( {pg_message, _From, _PgName, {shutdown, Cid}}, 
              State = #state{sock=S, cid=Cid} ) ->
    ?DEBUG("MQ got shutdown message.",[]),
    gen_tcp:close(S),
    {stop, normal, State};
handle_info( {pg_message, _From, _PgName, shutdown}, 
              State = #state{sock=S}) ->
    ?DEBUG("MQ got broadcasted shutdown message.", []),
    gen_tcp:close(S),
    {stop, normal, State};
handle_info(Info, State) -> 
    ?DEBUG("Got unknown message in MQ: ~p",[Info]),
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
terminate(_Reason, _State) -> ok.

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

%% @hidden
%% @doc Send an error as a message back over the wire.
handle_error( Err, _State = #state{sock=S} ) -> 
    gen_tcp:send( S, steve_util:encode_json([{<<"error">>,Err}]) ).

%% @hidden
%% @doc Send message to state server for processing, wait for reply and either
%% forward over wire or ignore.
%% @end
process( Msg , State = #state{sock=S}) ->
    ?DEBUG("Processing CAPI Message in State server: ~p", [Msg]),
    case steve_state:process_cmsg( Msg ) of
        {reply, Rep} -> 
            ?DEBUG("State server says to reply with: ~p",[Rep]),
            gen_tcp:send( S, capi:encode(Rep) ),
            {noreply, State};            
        {reply, Rep, Cid} ->
            ?DEBUG("State server says to reply with: ~p,~p",[Cid, Rep]),
            gen_tcp:send( S, capi:encode(Rep) ),
            {noreply, State#state{cid=Cid}};
        noreply ->
            ?DEBUG("State server says not to reply.", []),
            {noreply, State};
        {shutdown, Reason} -> 
            ?DEBUG("State server says for MQ to shutdown with reason: ~p",[Reason]),
            { stop, Reason, State}
    end.

