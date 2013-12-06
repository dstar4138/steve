%% Steve Application
%%  Implements the top level application supervisor for the Steve service.
%%
%% @author Alexander Dean
-module(steve_app).
-behaviour(application).
-include("debug.hrl").

%% Application callbacks
-export([start/2, prep_stop/1, stop/1]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called whenever an application is started using
%% application:start/[1,2], and should start the processes of the
%% application. If the application is structured according to the OTP
%% design principles as a supervision tree, this means starting the
%% top supervisor of the tree.
%%
%% @spec start(StartType, StartArgs) -> {ok, Pid} |
%%                                      {ok, Pid, State} |
%%                                      {error, Reason}
%%      StartType = normal | {takeover, Node} | {failover, Node}
%%      StartArgs = term()
%% @end
%%--------------------------------------------------------------------
start(_StartType, StartArgs) ->
    ?DEBUG("Checking user starting Steve..,", []),
    ok = check_user(),
    ?DEBUG("Starting Inets service for TFTP...",[]),
    {ok, _Pid} = startup_inets(),
    ?DEBUG("Starting Local persistant storage service...",[]),
    System = startup_mnesia(),
    ?DEBUG("Starting Steve Daemon...",[]),
    steve_sup:start_link( System, StartArgs ).

%%--------------------------------------------------------------------
%% @doc
%% Called by the application module right before shutting the rest of 
%% the system down. We modify and use this for debugging.
%%
%% @spec prep_stop( State ) -> ok.
%% @end
%%--------------------------------------------------------------------
prep_stop( _State ) ->
    ?DEBUG("Stopping Steve Daemon...",[]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called whenever an application has stopped. It
%% is intended to be the opposite of Module:start/2 and should do
%% any necessary cleaning up. The return value is ignored.
%%
%% @spec stop(State) -> void()
%% @end
%%--------------------------------------------------------------------
stop(_State) ->
    ok.


%%%===================================================================
%%% Internal Functions
%%%===================================================================

%% @hidden
%% @doc Starts up the inets service and the tftp server for file transactions.
startup_inets() ->
    case inets:start() of
        ok  -> inets:start(tftp, steve_ftp:get_config());
        Err -> Err
    end.

%% @hidden
%% @doc Starts the Mnesia database based on application environment or the
%%  starting arguments.
%% @end
startup_mnesia() -> 
    SaveDir = case application:get_env(steve, db_loc) of
                    undefined -> steve_util:getrootdir()++"/db";
                    {ok, Dir} -> Dir
              end,
    steve_db:verify_install(SaveDir). % Will start Mnesia daemon if not running.

%% @hidden
%% @doc Checks to make sure the proper user is running Steve and verifies that
%%   we definitely aren't root.
%% @end
check_user() -> 
    WhoAmI = steve_util:trim( os:cmd("whoami") ),
    case application:get_env( steve, user ) of
        {ok, User} ->
            S = steve_util:tostr(User),
            if S == WhoAmI -> ok;
               true ->
                  ?ERROR("steve:check_user","Not running as ~p!",[User]),
                  {error, baduser}
            end;
        undefined -> 
            if WhoAmI == "root" -> 
                  ?ERROR("steve:check_user","DO NOT RUN AS ROOT!",[]),
                  {error, baduser};
               true -> ok
            end
    end.
