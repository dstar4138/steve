%% Steve Top-level Supervisor
%%  Primary top level supervisor for the Steve service.
%%
%% @author Alexander Dean
-module(steve_sup).
-behaviour(supervisor).
-include("debug.hrl").

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(Mod, Type, Args), {Mod, {Mod, start_link, Args},
                                     permanent, 5000, Type, [Mod]}).

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
start_link() -> %TODO: Take configuration data to modify state server.
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
init([]) ->
    {ok, {{one_for_one, 5, 10}, [
                ?CHILD(steve_conn, worker, []), % TCP Server
                ?CHILD(steve_comp_sup, supervisor, []), % Computation Server
                ?CHILD(steve_state, worker, []) % State Server
         ]}}.

