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

%% Supervisor callbacks
-export([init/1]).

-define(CSUP_INIT, {ok, {
    {simple_one_for_one, 0, 1},  % Don't start computations on your own 
                                 % (steve_state will tell you). If this crashes
                                 % we're gunna have a bad time, so handle later.
    [{steve_comp, 
        {steve_comp, start_link, []},  
        temporary,  % If it crashes, don't restart. Steve will know and handle.
        5000,
        worker,
        [steve_comp]} 
    ]}}).



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
init([]) -> ?CSUP_INIT().

