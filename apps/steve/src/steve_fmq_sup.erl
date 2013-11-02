%% Steve Friend Message Queue Supervisor
%%
%%  The Connection server will spawn new message queues underneith this 
%%  supervisor.
%%
%% @author Alexander Dean
-module(steve_fmq_sup).
-behaviour(supervisor).

-include("debug.hrl").

% THE TYPE OF MQ IMPLEMENTATION.
-define(MQ, steve_fmq).

%% API
-export([start_link/0]).
-export([start_mq/1, stop_mq/1]).

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
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc
%%  Starts a Message queue Worker Process.
%%
%% @spec start_computation( ActionList ) -> {ok, Pid} 
%% @end
%%--------------------------------------------------------------------
start_mq( Args ) ->
    ?DEBUG("Starting Mq (~p)~n",[Args]),
    supervisor:start_child(?MODULE, Args).

%%--------------------------------------------------------------------
%% @doc
%%  Stops a computation worker process.
%%
%% @spec stop_computation( Pid ) -> ok.
%% @end
%%--------------------------------------------------------------------
stop_mq( Pid ) ->
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

