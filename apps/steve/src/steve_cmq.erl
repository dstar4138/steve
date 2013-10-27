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
                cid,  % Client ID for internal reference.
                msgs, % Messages waiting to send out to client.
                old_stream = nil % Current stream needing to parse.
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
handle_call(_Request, _From, State) ->
    {reply, error, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

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
handle_info({tcp, _Socket, RawData}, State = #state{ old_stream = S }) ->
    case capi:parse( RawData, S ) of
        {ok, Msgs, NewS} -> 
            process( Msgs ), 
            {noreply, State#state{old_stream=NewS}};
        {error, Msgs, Err} ->
            process( Msgs ), 
            handle_error( Err ),
            {noreply, State}
    end;
handle_info( {pg_message, _From, _PgName, {shutdown, Cid}}, 
              State = #state{sock=S, cid=Cid} ) ->
    gen_tcp:close(S),
    {stop, normal, State};
handle_info( {pg_message, _From, _PgName, shutdown}, 
              State = #state{sock=S}) ->
    gen_tcp:close(S),
    {stop, normal, State};
handle_info(_Info, State) -> {noreply, State}.

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

handle_error( Err ) -> ?DEBUG("EMIT ERROR: ~p~n",[Err]), ok.
process( [] ) -> ok;
process( [H|R] ) -> ?DEBUG("PROCESS MSG: ~p~n",[H]), process( R ).

