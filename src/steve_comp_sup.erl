%% Computation supervisor
%%   Monitors on-going computations for failures and then restarts them if they
%%   crash. This restarting process triggers reporting errors to requesting
%%   friend.
%%
%% @author Alexander Dean
-module(steve_comp_sup).
-behaviour(supervisor).

-include("debug.hrl").

%% API
-export([start_link/0]).
-export([start_computation/1, stop_computation/1]).

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
%%  Starts a computation worker process.
%%
%% @spec start_computation( ActionList ) -> {ok, Pid} 
%% @end
%%--------------------------------------------------------------------
start_computation( Args ) ->
    ?DEBUG("Starting Computation (~p)~n",[Args]),
    supervisor:start_child(?MODULE, Args).

%%--------------------------------------------------------------------
%% @doc
%%  Stops a computation worker process.
%%
%% @spec stop_computation( Pid ) -> ok.
%% @end
%%--------------------------------------------------------------------
stop_computation( Pid ) ->
    ?DEBUG("Stopping Computation (~p)~n", [Pid]),
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
    % Don't start computations on your own 
    % (steve_state will tell you). If this crashes
    % we're gunna have a bad time, so handle later.
    SupFlags = {simple_one_for_one, 0, 1}, 

    Worker = { undefined, 
               {steve_comp, start_link, []},  
               temporary,
               brutal_kill,
               worker,
               [steve_comp] }, 

    {ok, { SupFlags, [ Worker ] }}.

