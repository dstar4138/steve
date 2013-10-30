%% Steve File Transfer Server
%%
%%  Monitor and accept file transfers from clients. We only accept certain file
%%  types and structures, namely only ZIP files which are named as the 
%%  Computational ID sent to the client by Steve. This module is a wrapper 
%%  around the tftp_file module, I have merely added the security checks 
%%  Steve needs along with an additional internal API.
%%
%% @author Alexander Dean
-module(steve_ftp).

-include("steve.hrl").
-include("debug.hrl").

% This is a TFTP Callback module for handling File Transfers from clients.
-behaviour(tftp).
-export([prepare/6, open/6, read/1, write/2, abort/3]).

-define(DEFAULT_CONFIG, [ {port,0},
                          {root_dir, ?DEFAULT_STEVEDIR++"/compserve"},
                          {debug,all},
                          {callback, {".*", ?MODULE, []}} ]).

% Internal Steve API.
-export([ get_config/0, % Get TFTPd Startup Config, called in steve_app:start/2
          get_conn_port/0  % Grabs the client welcome port.
        ]). 

%% ===========================================================================
%% Steve API Calls
%% ===========================================================================

%% @doc Get the default configuration for TFTP.
-spec get_config() -> string().
get_config() ->
    case application:get_env(steve, tftp) of
        undefined -> ?DEFAULT_CONFIG;
        {ok, P} -> P
    end.

%% @doc Get the port Clients will need to connect to for file transfers.
-spec get_conn_port() -> integer().
get_conn_port() -> 69. %TODO: Port is 0, so it will auto-scan. Grab from inets.

%% ===========================================================================
%% TFTP Callback Functions
%% ===========================================================================

%% @doc Prepares open of a file on the client side.
prepare( Peer, Access, Filename, Mode, SuggestedOptions, Initial ) ->
    case validate_options( Peer, Access, Filename ) of
        true  -> tftp_file:prepare( Peer, Access, Filename, Mode, SuggestedOptions, Initial );
        false -> {error, {eacces, "Invalid Filename for that type of access."}}
    end.

%% ------------------------------------------------------------------------- %%
%% The following fall through to tftp_file module for standard file handling %%

%% @doc Opens a file for read/write access.
open( Peer, Access, Filename, Mode, SuggestedOptions, Initial ) ->
    tftp_file:open( Peer, Access, Filename, Mode, SuggestedOptions, Initial ).

%% @doc Reads a chunk of a file from the wire.
read( State ) -> tftp_file:read( State ).
    
%% @doc Writes a chunk from the wire to a file.
write( Bin, State ) -> tftp_file:write( Bin, State ).

%% @doc Aborts the file transfer.
abort( Code, Text, State) -> tftp_file:abort( Code, Text, State ).
    

%% ===========================================================================
%% Internal Functionality
%% ===========================================================================

%% @hidden
%% @doc Validate whether Peer has Access on Filename.
validate_options( Peer, Access, Filename ) ->
   true. %TODO: Check steve_state for whether Peer has Access on Filename. 
