%% Steve Top-level Supervisor
%%  Primary top level supervisor for the Steve service.
%%
%% @author Alexander Dean
-module(steve_sup).
-behaviour(supervisor).
-include("debug.hrl").

-define(DEFAULT_PPORT, 50505).
-define(DEFAULT_CPORT, 51343).
-define(DEFAULT_RCFILE, "~/.config/steve/steverc").

%% API
-export([start_link/2]).

%% Supervisor callbacks
-export([init/1]).

-define(NCHILD(ID, Mod, Type, Args), {ID, {Mod, start_link, Args},
                                     permanent, 5000, Type, [Mod]}).
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
start_link( System, StartArgs ) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [System, StartArgs]).

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
init( [System, StartArgs] ) ->
%    process_flag(trap_exit, true),
    {ok, PPort, CPort} = get_conn_ports(),
    {ok, RCFile} = get_rcfile(),
    Args = [{rcfile,RCFile},{sys,System}|StartArgs],
    {ok, {{one_for_one, 5, 10}, [
                ?CHILD(steve_fmq_sup, supervisor, [])  % F-CONN MQ Supervisor
               ,?CHILD(steve_cmq_sup, supervisor, [])  % C-CONN MQ Supervisor
               ,?CHILD(steve_comp_sup, supervisor, []) % Computation Server
               ,?CHILD(steve_state, worker, [Args])      % State Server
               ,?NCHILD(fconn, steve_conn, worker, 
                        [friends, steve_fmq_sup, PPort]) % Peer Server
               ,?NCHILD(cconn, steve_conn, worker, 
                        [clients, steve_cmq_sup, CPort]) % Client Server
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

