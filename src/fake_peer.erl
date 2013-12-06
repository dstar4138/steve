%% Fake Peer Module
%%
%%  This module simulates a connected peer so you do not have to set up a bunch
%%  of other computers and bring networking issues into play as well. This
%%  module uses the exact same communication module and papi wrapper functions
%%  that Steve uses so you can see both sides of the communication in the shell.
%%  Note it still uses socket communication so it can be used remotely as well.
%%
%%  @author Alexander Dean
-module(fake_peer).
-include("debug.hrl").
-include("papi.hrl").
-include("steve_obj.hrl").

-export([start/1, stop/1]).
-export([send_raw/2, send_papi/2]).
-export([get_samples/0, run_sample/2]).
-export([mk_papi/3,mk_papi/4]).

%% gen_fsm callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record( state, { fid, conn } ).

-define(SOCK_OPTS,[ binary, {packet,line}, {keepalive, true}, {active, false}]).

-define(FAKE_GROUP, fake_friends).
-define(LOCAL_FRIEND, #friend{ id= <<>>, name="local", rep=42 }).
-define(SAMPLE_MSGS, []).

%%%===================================================================
%%% API
%%%===================================================================

start( Port ) ->
    FID = steve_util:uuid(),
    Sfid = steve_util:uuid_to_str(FID),
    LocalName = list_to_atom(lists:concat([fakepeer_,Sfid])),
    case gen_server:start_link({local, LocalName}, ?MODULE, [FID], []) of
        ignore -> {error, ignore};
        {error, R} -> {error, R};
        {ok, Pid} ->
            gen_server:cast( Pid, {build_sock, Port} ),
            io:fwrite("FAKEPEER: Connected to Steve on port( ~p ) with fid( ~s ).~n", 
                      [Port,Sfid]),
            {ok, Pid}
    end.

stop( Pid ) -> gen_server:call( Pid, shutdown ).


send_raw( Pid, Msg ) -> gen_server:cast( Pid, {send, Msg} ).
send_papi( Pid, Papim ) -> 
    Msg = papi:encode( Papim ),
    gen_server:cast( Pid, {send, Msg} ).

get_samples() ->
    io:fwrite("Possible values for sample runs:~n"),
    lists:map(
      fun( M ) ->
        io:fwrite("- ~s~n", msg_desc(M#papim.type))
      end, ?SAMPLE_MSGS ).

run_sample( Pid, PapiID ) ->
    lists:takewhile( fun( M ) ->
        if M#papim.type == PapiID -> send_papi( Pid, M ), false;
           true -> true
        end
    end, ?SAMPLE_MSGS ).

mk_papi( Type, Cnt, Val ) ->
    {ok, #papim{ type = Type, cnt = Cnt, val = Val }}.
mk_papi( From, Type, Cnt, Val ) ->
    {ok, #papim{ from=From, type=Type, cnt=Cnt, val=Val }}.


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @doc Initialize the Fake Peer
init([FID]) ->
%   pg:create(?FAKE_GROUP),
    {ok, #state{ fid = FID }}.

%% @doc Calls aren't really used.
handle_call( shutdown, _, State ) -> {stop, State};
handle_call( _Request, _, State ) -> {reply, ok, State}.

%% @doc Sending messages to the remote
handle_cast({build_sock, Port}, State ) ->
    Sock = setup_conn( Port ),
    inet:setopts( Sock, [{active,once}] ),
    NewState=State#state{conn=Sock},
    {noreply, NewState};
handle_cast({send, Msg}, #state{conn=Conn} = State) ->
    comm( Msg, Conn ),
    {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.

%% @doc Handle misc tcp data.
handle_info({tcp, S, RawData}, State ) ->
    inet:setopts( S, [{active, once}] ),
    recv( RawData ),
    {noreply, State};
handle_info({tcp_closed, _S}, State) ->
    io:fwrite("FAKEPEER: Remote closed socket.~n"),
    {stop, normal, State};
handle_info(_Info, State) -> {noreply, State}.

%% @doc Following callbacks are ignored.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

recv( Msg ) -> io:fwrite("FAKEPEER: Recv = ~p~n", Msg).
comm( Msg, Socket ) ->
    io:fwrite("FAKEPEER: Send = ~p~n", Msg ),
%    pg:send( ?FAKE_GROUP, {send, ?LOCAL_FRIEND, Msg} ).
    gen_tcp:send( Socket, Msg ).

setup_conn( Port ) -> 
    {ok, Socket} = gen_tcp:connect( "localhost", Port, ?SOCK_OPTS ),
%    steve_fmq:create( ?FAKE_GROUP, ?LOCAL_FRIEND, Socket ),
     Socket.

msg_desc(Type) -> 
    case Type of
        0 -> "0: Request for computation.";
        1 -> "1: Acknowledgement of capability.";
        2 -> "2: Broadcast computation result.";
        3 -> "3: Request for particular computation result.";
        4 -> "4: Reputation check.";
        5 -> "5: Reputation acknowledgement.";
        6 -> "6: Friend Request.";
        7 -> "7: Friend acknowledgement."
    end.

