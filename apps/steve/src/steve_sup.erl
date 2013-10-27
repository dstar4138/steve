%% Steve Top-level Supervisor
%%  Primary top level supervisor for the Steve service.
%%
%% @author Alexander Dean
-module(steve_sup).
-behaviour(supervisor).
-include("debug.hrl").

-define(DEFAULT_PPORT, 50505).
-define(DEFAULT_CPORT, 51343).
-define(DEFAULT_RCFILE, "~/.steverc").

%% API
-export([start_link/1]).

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
%% @spec start_link( Args ) -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link( StartArgs ) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, StartArgs).

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
init( StartArgs ) ->
    {ok, PPort, CPort} = get_conn_ports(),
    {ok, RCFile} = get_rcfile(),
    {ok, {{one_for_one, 5, 10}, [
                ?CHILD(steve_conn, worker, [friends, steve_fmq, PPort]), % Peer Server
                ?CHILD(steve_conn, worker, [clients, steve_cmq, CPort]), % Client Server
                ?CHILD(steve_comp_sup, supervisor, []), % Computation Server
                ?CHILD(steve_state, worker, [{rcfile,RCFile}|StartArgs]) % State Server
         ]}}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

% Checks the application environment for ports, otherwise uses defaults.
get_conn_ports() ->
    PPort = case application:get_env(steve, fport) of
        undefined -> ?DEFAULT_PPORT;
        {ok, P} -> P
    end,
    CPort = case application:get_env(steve, cport) of
        undefined -> ?DEFAULT_CPORT;
        {ok, C} -> C
    end,
    {ok, PPort, CPort}.

% Reads in the RC File, if both are missing, then this will cause a pattern
% match error in init/1 above. This is fine as we shouldn't continue without
% a requests definitition and capability list.
get_rcfile() ->
    RCFile = case application:get_env(steve, rcfile) of
        undefined -> ?DEFAULT_RCFILE;
        {ok, F} -> F
    end,
    steve_util:loadrc( RCFile ).

