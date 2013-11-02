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
-define(ROOTDIR, {root_dir,  steve_util:getrootdir()++"/compserve"}).
-define(DEFAULT_CONFIG, [ {port,0},
                          {debug,all},
                          {callback, {".*", ?MODULE, [?ROOTDIR]}} ]).

% Internal Steve API.
-export([ get_config/0, % Get TFTPd Startup Config, called in steve_app:start/2
          get_conn_port/0  % Grabs the client welcome port.
        ]). 

%% Overlap's tftp_file's state with a filename check.
-record( overlap_state, { internal, filename } ).

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
-spec get_conn_port() -> integer() | {error, Reason :: any()}.
get_conn_port() -> 
    case lists:keysearch(tftpd, 1, inets:services_info()) of
        {value, {tftpd, _Pid, Opts}} -> 
            element(2, lists:keyfind( port, 1, Opts ));
        false -> {error, "TFTP service not started."}
    end.


%% ===========================================================================
%% TFTP Callback Functions
%% ===========================================================================

%% @doc Prepares open of a file on the client side.
prepare( Peer, Access, Filename, Mode, SuggestedOptions, Initial ) ->
    case validate_options( Peer, Access, Filename ) of
        false -> {error, {eacces, "Invalid Filename for that type of access."}};
        true  -> (case 
            tftp_file:prepare( Peer, Access, Filename, Mode, SuggestedOptions, Initial )
        of
            {ok, AcceptedOptions, State} -> 
                          {ok, AcceptedOptions, wrap({Filename},State)};
            Msg -> Msg
        end)
    end.

%% ------------------------------------------------------------------------- %%
%% The following fall through to tftp_file module for standard file handling %%

%% @doc Opens a file for read/write access.
open( Peer, Access, Filename, Mode, SuggestedOptions, Initial ) ->
    case
        tftp_file:open( Peer, Access, Filename, Mode, SuggestedOptions, Initial )
    of
        {ok, Opts, State} -> {ok, Opts, wrap( {Filename}, State )};
        Msg -> Msg
    end.

%% @doc Reads a chunk of a file from the wire. Triggers state server 
%% notification when read is finished.
%% @end
read( State ) -> 
    {X, I} = unwrap( State ),
    case tftp_file:read( I ) of
        {more, Bin, NewState} -> 
            {more, Bin, wrap( X, NewState )};
        {last, Bin, FileSize} ->
            trigger(finish_read, X, FileSize),
            {last, Bin, FileSize};
        Msg -> Msg
    end.
    
%% @doc Writes a chunk from the wire to a file.
write( Bin, State ) -> 
    {X, I} = unwrap( State ),
    case tftp_file:write( Bin, I ) of
        {more, NewState} -> {more, wrap( X, NewState )};
        {last, FileSize} -> 
            trigger( finish_write, X, FileSize ),
            {last, FileSize};
        Msg -> Msg
    end.

%% @doc Aborts the file transfer.
abort( Code, Text, State ) -> 
    {_, I} = unwrap( State ),
    tftp_file:abort( Code, Text, I ).
    

%% ===========================================================================
%% Internal Functionality
%% ===========================================================================

%% @hidden
%% @doc Validate whether Peer has Access on Filename. Filenames must be the
%%  Command ID followed by the 'zip' extension. If its a read, it must be a
%%  read for a result value and thus appended with 'res.'. Note the filename
%%  can be written with or without '-'. However, reading will always have them.
%% @end
validate_options( Peer, write, FileName ) ->
    case get_compid( FileName ) of
        {ok, CompID} -> steve_state:peer_write_perm_check( Peer, CompID );
        _ -> false
    end;
validate_options( Peer, read, "res." ++ FileName ) ->
    case get_compid( FileName ) of
        {ok, CompID} -> steve_state:peer_read_perm_check( Peer, CompID );
        _ -> false
    end;
validate_options( _, _, _ ) -> true. %TODO: Set to false after testing!!


%% @hidden 
%% @doc Extract the UUID from the Filename by doing easier binary matching.
get_compid( L ) when is_list( L ) -> get_compid( erlang:list_to_binary( L ) );
get_compid( << Name:(36*8), ".zip" >> ) -> % If file has dashes like normal uuid
    {ok, steve_util:bits_to_uuid( Name ) };
get_compid( << Name:(32*8), ".zip" >> ) -> % If the file is missing dashes.
    {ok, steve_util:bits_to_uuid( Name ) };
get_compid( _ ) -> {error, badarg}.


%% @hidden
%% @doc Unwrap our overlapping state to grab the internal module's state.
unwrap( #overlap_state{ internal = I } = S ) -> {pullout(S), I};
unwrap( UnknownState ) -> { nil, UnknownState }.


%% @hidden
%% @doc Just grab out our additional wrapper data and save to a tuple for 
%%  reinsertion.
%% @end
pullout( #overlap_state{ filename = F} ) -> {F}.


%% @hidden
%% @doc Opposite of unwrap/1, will reinsert our pulled-out data into our
%%   wrapper state.
%% @end
wrap( nil, UnknownState ) -> UnknownState;
wrap( {F}, State ) -> #overlap_state{ internal = State, filename = F }.


%% @hidden
%% @doc Triggers an event on the state server based on the file that was just
%%   read/written to. If the file is now needed by another steve node for 
%%   processing, Steve needs to know it has the file.
%% @end
trigger( Action, {FileName}, FileSize ) ->
    case get_compid( FileName ) of
        {ok, CompID} ->
            steve_util:peer_file_event( CompID, {Action, FileName, FileSize} );
        _ -> 
            ?ERROR( "steve_ftp:trigger", "Unable to get UUID: ~p",[FileName])
    end.

