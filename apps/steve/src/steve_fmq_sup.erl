%% Steve Friend Message Queue Supervisor
%%
%%  The Connection server will spawn new message queues underneith this 
%%  supervisor. It handles the connection logic and process group addition.
%%
%%  Ultimately I would like to merge this with steve_cmq_sup then abstract
%%  the entire async communication service to an external application.
%%
%% @author Alexander Dean
-module(steve_fmq_sup).
-behaviour(supervisor).

-include("debug.hrl").

% THE TYPE OF MQ IMPLEMENTATION.
-define(MQ, steve_fmq).

%% API
-export([start_link/0]).
-export([start_mq/3, stop_mq/1]).

%% Supervisor callbacks
-export([init/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc
%%  Starts a Message queue Worker Process.
%%
%% @spec start_mq( Group, FriendObj, Socket ) -> {ok, Pid} 
%% @end
%%--------------------------------------------------------------------
start_mq( Group, FriendObj, Socket ) ->
    ?DEBUG("Starting Mq (~p)~n",[[Group,FriendObj,Socket]]),
    {ok, Pid} = supervisor:start_child(?MODULE, []),
    ok = ?MQ:set_socket( Pid, FriendObj, Socket ),
    ok = gen_tcp:controlling_process( Socket, Pid ),
    pg:join( Group, Pid ),
    {ok, Pid}.

%%--------------------------------------------------------------------
%% @doc
%%  Stops a computation worker process.
%%
%% @spec stop_computation( Pid ) -> ok.
%% @end
%%--------------------------------------------------------------------
stop_mq( Pid ) when is_pid( Pid ) ->
    ?DEBUG("Stopping Message Queue (~p)~n", [Pid]),
    supervisor:stop_child(?MODULE, Pid).


%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) -> 
    % Don't start message queues on your own 
    SupFlags = {simple_one_for_one, 0, 1}, 

    Worker = { undefined, 
               {?MQ, start_link, []},  
               temporary,
               brutal_kill,
               worker,
               [?MQ] }, 

    {ok, { SupFlags, [ Worker ] }}.

