%% Steve persistant storage
%%
%%  Steve has a couple things it saves on harddisk in a database, namely
%%  whether the results for particular computation ID's have been finished
%%  and where they are located.
%%
%% @author Alexander Dean
-module(steve_db).

-include("debug.hrl").
-include("steve_obj.hrl").
-include("util_types.hrl").
-include_lib("stdlib/include/qlc.hrl").

%% Records for database store, aka the Schema. %%
%% ------------------------------------------- %%
%% Computation-Table : 
%%      ID            - UUID unique for each computation request.
%%      FID           - The Peer ID that is performing this computation.
%%      Result        - whether this current node has heard about a result.
%%      HasResArchive - whether this computation will require a result archive.
%%      ArchiveHash   - A Hash of the archive, used for checksums.
-record( t_comp, {
           id                   :: uid(),
           fid                  :: uid(),
           result = false       :: boolean(),
           has_resarchive = nil :: nil | boolean(),
           archive_hash = nil   :: nil | integer() 
          }).
%% ------------------------------------------- %%
%% Local-Computation-ID-Lookup-Table:
%%  (If a user selects multiple friends to start computing, they are linked
%%  through here.)
%%      ID           - The Local Computation ID given to a client.
%%      Comps        - The ID's sent to each Friend (unique one per peer).
%%      HasArchive   - Does the primary computation have an archive to send?
%%      ArchiveHash  - A hash of that archive for verification.
%%
-record(t_multicomp, {
           id                  :: uid(),
           req                 :: 'REQUEST'(),
           comps = []          :: [{uid(),uid()}],
           has_archive = false :: boolean(),
           archive_hash = nil  :: nil | binary()
          }).
%% ------------------------------------------- %%
%% Friend-Table
%%      ID              - ID given by other node.
%%      Name            - Personal name we give this Friend account.
%%      LastKnownAddr   - Last known address of the friend, for reconnects
%%      Reputation      - Reputation of the Friend
-record( t_friend, {
           id :: uid(),
           name :: binary(),
           last_known_addr :: tuple(), %TODO, define better type
           reputation :: 'REPUTATION'()
          }).
%% ------------------------------------------- %%
%% My State Table
%%      Simple key-value store that Steve will save critical values it will
%%      need upon crash/reboot.
%%      
-record( t_me, { 
           key :: atom(),
           val :: term()
          }).
%% ------------------------------------------- %%
-define(TABLES, [
                 {t_me, record_info(fields, t_me), [key]},
                 {t_comp, record_info(fields, t_comp), [id,cid]},
                 {t_friend, record_info(fields, t_friend), [id]}
                ]).

-export( [ verify_install/1 ] ).
-export( [ set_state_key/2, get_state_key/1 ] ).
-export( [ add_new_computation/1, add_comp_handler/2 ]). 
-export( [ has_handler_result/1, has_all_results/1, 
           get_comp/1, get_missing_result_list/0 ] ).
-export( [ lookup_friend/1, add_update_friend/1, get_last_addrs/0 ] ).

%%% ==========================================================================
%%% API
%%% ========================================================================== 

%% @doc Install the Database on the local system based on the passed in options.
verify_install( Dir ) -> 
    ok = application:start(mnesia),
    ok = create_schema( Dir ),
    ok = make_tables( ),
    connect_to_mnesia().


%% @doc Set a value in the state's key-value store. Should be used sparingly!!
set_state_key( Key, Val ) when is_atom( Key ) ->
    Transaction = fun() ->
        mnesia:write(#t_me{key=Key, val=Val})
    end,
    run_tran( Transaction, ok ).


%% @doc Grab a value from the state key-value store.
get_state_key( Key ) when is_atom( Key ) ->
    Transaction = fun() ->
        qlc:e( qlc:q( [ {Key, U#t_me.val} || U <- mnesia:table(t_me), 
                                             U#t_me.key =:= Key ] ) )
    end,
    run_tran( Transaction, ok ).


%% @doc Adds a new computation, created by the client. This needs to be called
%%   before calling add_comp_handler/2, to signal that a friend was accepted to
%%   compute a request.
%% @end
add_new_computation( Comp ) when is_record( Comp, computation ) ->
    {Id, Hash, Archive, Req} = {Comp#computation.id,
                                Comp#computation.hash,
                                Comp#computation.has_archive,
                                Comp#computation.req },
    Transaction = fun() -> 
        mnesia:write( #t_multicomp{ id=Id, 
                                    req=Req, 
                                    comps=[], 
                                    has_archive=Archive, 
                                    archive_hash=Hash} )
    end,
    run_tran( Transaction, ok ).


%% @doc Add a computation handler. This saves the fact that a friend is being
%%   used to compute the request. It will return the ID that should be tied to
%%   the Friend's computation acknowledgement.
%& @end
add_comp_handler( Comp, Friend ) when is_record( Comp, computation ) and
                                      is_record( Friend, friend ) ->
    CompID = Comp#computation.id,
    FriendID = Friend#friend.id,
    NewCompID = steve_util:uuid(),
    Transaction = fun() ->
        mnesia:write(#t_comp{ id=NewCompID, fid=FriendID }),
        [C] = mnesia:wread({t_multicomp, CompID}),
        mnesia:write(C#t_multicomp{comps=[{FriendID, NewCompID}|
                                          C#t_multicomp.comps]})
    end,
    run_tran( Transaction, {ok, NewCompID} ).


%% @doc Check if a particular CID has a result that has been saved on the local
%%   machine. This CID must be one of the ones sent out to a Friend. To check
%%   if all friends have returned, run has_all_results/1.
%% @end
has_handler_result( CID )-> 
    Transaction = fun() ->
        case mnesia:read(t_comp, CID) of
            [ Row ] -> Row#t_comp.result;
            Bad -> ?DEBUG("has_result: ~p", [Bad]), Bad
        end
    end,
    run_tran( Transaction, false ).


%% @doc Runs through all friends accepted for a computation and check if we've
%%   recieved a solution for all of them.
%% @end
has_all_results( Comp ) when is_record( Comp, computation ) ->
    FCIDs = Comp#computation.friends_computing,
    Res = lists:map( fun has_handler_result/1, FCIDs ),
    lists:foldl( fun( X, A ) -> X andalso A end, true, Res ).


%% @doc Get the computation object for a particular CID.
get_comp( CID ) -> 
    % This transaction will build part of the computation, the other half
    % we will need to run on t_comp.
    Transaction = fun() ->
        Q = qlc:q([ { ?COMPUTATION( U#t_multicomp.id,
                                    U#t_multicomp.has_archive,
                                    U#t_multicomp.archive_hash,
                                    U#t_multicomp.req ),
                      U#t_multicomp.comps }
                    || U <- mnesia:table(t_multicomp),
                       U#t_multicomp.id =:= CID ]),
        qlc:e( Q )
    end,
    case run_tran( Transaction, {error, badarg} ) of
        {error, Reason} -> {error, Reason};
        {Comp, CIDs} when is_record( Comp, computation ) ->
            {Friends, Comps} = lists:unzip( CIDs ),
            capture_progress( Comp#computation{friends_computing=Friends},
                              Comps )
    end.

%% @doc Get the CID of all computations we do not have results for locally.
get_missing_result_list() -> 
    Transaction = fun() ->
        Q = qlc:q( [ U#t_comp.id || 
                     U <- mnesia:table(t_comp), 
                     U#t_comp.result =:= false ]),
        qlc:e( Q )
    end,
    run_tran( Transaction, [] ).


%% @doc Look up a friend either by name or ID. This returns a Friend object that
%%   can be passed to the new message queue.
%% @end
lookup_friend( {name, Name} ) -> 
    Transaction = fun() ->
        Q = qlc:q( [ ?FRIEND( U#t_friend.id,
                              U#t_friend.name,
                              U#t_friend.reputation,
                              U#t_friend.last_known_addr )
                     || U <- mnesia:table( t_friend ),
                        U#t_friend.name =:= Name ] ),
        qlc:e( Q )
    end,
    run_tran( Transaction, {error, badarg} );
lookup_friend( {id, ID} ) -> 
    Transaction = fun() ->
        Q = qlc:q( [ ?FRIEND( U#t_friend.id,
                              U#t_friend.name,
                              U#t_friend.reputation,
                              U#t_friend.last_known_addr )
                     || U <- mnesia:table( t_friend ),
                        U#t_friend.id =:= ID ] ),
        qlc:e( Q )
    end,
    run_tran( Transaction, {error, badarg} ).       


%% @doc Add or update a friend stored in the database. It will do a look up 
%%   based on the Friend object's ID.
%% @end
add_update_friend( FriendObj ) when is_record( FriendObj, friend ) -> 
    {ID, Name, Rep, Addr} = { FriendObj#friend.id,
                              FriendObj#friend.name,
                              FriendObj#friend.rep,
                              FriendObj#friend.addr },
    Transaction = fun() ->
        mnesia:write( #t_friend{ id=ID, 
                                 name=Name, 
                                 reputation=Rep, 
                                 last_known_addr=Addr} )
    end,
    run_tran( Transaction, ok ).


%% @doc Get the last known addresses of all friends in the database. This is
%%   called when the steve node first starts up. It will try to initiate 
%%   communication with all friends it last talked to.
%% @end
get_last_addrs() -> 
    Transaction = fun() ->
        qlc:e( qlc:q( [ U#t_friend.last_known_addr || 
                        U <- mnesia:table( t_friend ) ] ) )
    end,
    run_tran( Transaction, [] ).


%%% ==========================================================================
%%% Private Functionality
%%% ========================================================================== 

%% @hidden
%% @doc Pushes the current progress from CIDs into the Computation object.
capture_progress( Comp, CIDs ) when is_record( Comp, computation ) and
                                    is_list( CIDs ) ->
    Res = lists:map( fun has_handler_result/1, CIDs ),
    AllFin = lists:foldl( fun( X, A ) -> X andalso A end, true, Res ),
    AtLeastOne = lists:foldl( fun(X,A)-> X orelse A end, false, Res ),
    Comp#computation{ finished = AtLeastOne, all_finished = AllFin }.

%% @hidden
%% @doc Creates the local files on disc to store the persistant state.
create_schema( Dir ) ->
    try 
        application:set_env( mnesia, dir, Dir ), % Override save location.
        mnesia:create_schema([node()])
    catch 
        exit:{_,{already_exists,_}} -> ok;
        Exit:Reason ->
            ?ERROR( "steve_db:create_schema",
                    "Failed to create system schema: ~p:~p", [Exit,Reason]),
            {error, Reason}
    end.

%% @hidden
%% @doc Creates each table in the database.
make_tables() ->
    F = fun(Tab = {TabName, _, _}, Acc) ->
                I = try mnesia:table_info(TabName, all) catch _:_ -> [] end,
                case length(I) of
                    0 ->
                        create_table( Tab ),
                        [Tab|Acc];
                    _ ->
                        Acc
                end
        end,
    NewlyMadeTables = lists:foldl(F, [], ?TABLES),
    if length(NewlyMadeTables) > 0 ->
           ?DEBUG("Finished building local storage for the first time.",[]), ok;
       true -> ok
    end.

%% @hidden
%% @doc Creates an individual table according to the persist options. Taken from
%%   EMPDB project.
%% @end 
create_table( {TabName, Info, Index} ) ->
    ?DEBUG("Building table ~p in mnesia.",[TabName]),
    DefaultOpts = [{attributes, Info}, {type, ordered_set}, {disc_copies, [node()]}],
    CrOption = if
                   length(Index) > 0 -> [{index, Index} | DefaultOpts ];
                   true -> DefaultOpts
               end,
    case mnesia:create_table( TabName, CrOption ) of
        {atomic, ok} -> fill_defaults( TabName );
        {aborted,Reason} ->
            ?ERROR("Failed to create table ~p because: ~p", [TabName, Reason])
    end.

%% @hidden
%% @doc Assumes Mnesia application is running and will wait for table access. 
%%   Will fail if another Steve application is currently running on the same 
%%   node.
%% @end
connect_to_mnesia() ->
    case mnesia:wait_for_tables( ?TABLES, 5000 ) of
        ok -> load_state();
        {timeout, BadTabList} -> 
            (case mnesia:wait_for_tables( BadTabList, 5000 ) of
                 {timeout, _} -> {error, timeout};
                 ok -> load_state();
                 M -> M
             end);
        {error, Reason} -> {error, Reason}
    end.

%% @hidden
%% @doc Load the current state as arguments to return.
load_state() ->
    Transaction = fun() ->
                          qlc:e( qlc:q( [ { U#t_me.key, U#t_me.val } ||
                                          U <- mnesia:table( t_me ) ] ) )
                  end,
    run_tran( Transaction, [] ).

%% @hidden
%% @doc Fill particular tables with their default values, which only happens 
%%   if the table has never been created.
%% @end
fill_defaults( t_me ) ->
    Vals = [ % Steve, when it first starts up generates a UUID for itself to 
            % send to friends. This will be its personal peer ID.
            { my_id, steve_util:uuid() }
           ],
    Transaction = fun() ->
           lists:foreach( fun( {Key,Val} ) -> 
                   mnesia:write( #t_me{ key=Key, val=Val } ) 
                          end, Vals )
                  end,
    run_tran( Transaction, ok );
fill_defaults( _ ) -> ok.

%% @hidden
%% @doc A wrapper for running a transaction on the Steve Persistant store. Will
%%   Return 'Ret' upon successful completion (unless it returns a value 
%%   explicitly), {error, Reason} otherwise.
%% @end
run_tran( F, Ret ) ->
    try mnesia:transaction(F) of
        {aborted, Reason} -> {error, Reason};
        {atomic, [Res]}   -> Res;
        {atomic, ok}      -> Ret;
        {atomic, Drop}    -> Drop
    catch error: Reason -> {error, Reason} end.

