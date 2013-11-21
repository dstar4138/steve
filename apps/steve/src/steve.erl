%% Steve User API Module
%%
%%   This module consists of some useful function calls administrators can use
%%   from the erlang shell when running Steve nodes. These can also be used for
%%   testing misc features.
%%
%% @author Alexander Dean
-module(steve).

% System startup stuff.
-export([start/1, start/0, stop/0]).

% Hand adjusting configuration.
-export([ add_peer/2, list_connections/0 ]).

-define(BREAKER,"=========================================================~n").

%%% =========================================================================
%%% API
%%% =========================================================================

%% @doc Start the steve daemon with overrided options.
start( OverrideOptions ) ->
    application:start(steve, OverrideOptions).

%% @doc Start the steve daemon with the default options from steve.app.
start() -> application:start(steve).

%% @doc Stop the running steve daemon.
stop() -> application:stop().


%% @doc Add a peer/friend for steve to try and connect to. It will return with
%%   ok immediately, but watch the tty for the friend message queue logging.
%% @end
add_peer( _IP, _Port ) -> 
    case check_if_running() of
        false -> io:fwrite("Steve daemon has not been started.");
        true -> ok %TODO: implement.
    end.

%% @doc Lists all currently connected friends' and clients' IP:Port and ID.
list_connections() ->
    case check_if_running() of
        false -> io:fwrite("Steve daemon has not been started.");
        true  ->
            io:fwrite("Connections:~n"), 
            io:fwrite(?BREAKER),
            io:fwrite("Connected Friends:~n"),
            lists:foldl( fun print_conn/2, ok, steve_conn:get_friend_list()),
            io:fwrite(?BREAKER), 
            io:fwrite("Connected Clients:~n"),
            lists:foldl( fun print_conn/2, ok, steve_conn:get_client_list()),
            io:fwrite(?BREAKER)
    end.
        


%%% =========================================================================
%%% Internal Functionality
%%% =========================================================================

%% @private
%% @doc Checks if steve is running on the local VM.
check_if_running() ->
    lists:keymember( steve, 1, application:which_applications() ).

%% @private
%% @doc Prints a connection of they style: {IP, Port, ID, Status}.
print_conn( {IP, Port, ID, Status}, R ) ->
    try
        PrintID = steve_util:uuid_to_str(ID),
        io:format("ID:{~p} - ~p:~p - ~p~n",[PrintID,IP,Port,Status])
    catch _:_ -> ok end,
    R.

