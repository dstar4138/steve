%% The Local System Action Handler
%%
%% Computations are essentially a set of computations which interact with the
%% system and the computation's request data. The Action Handler ignores the
%% contents of these and is merely a callthrough between the erlexec 
%% dependency and the steve_comp module.
%%
%% To define another action, all one would need to do is add another run clause.
%%
%% @author Alexander Dean
-module(steve_action).

-include("debug.hrl").
-define(OPTS, [ debug ] ).

-export( [start/0] ).
-export( [do/3, default_vars/0] ).

%% @doc Start up the Exec port so that we can run external OS processes.
start() -> exec:start( ?OPTS ).

%% @doc Due to the complications that would arrise if variables were not 
%%   present It would be a good idea to use the proplist returned and modify
%%   it, rather than trying to build your own.
%% @end
default_vars() ->
    RootDir = steve_util:getrootdir(),
    [{"trash", cat([RootDir,"/trash"])},
     {"compname", ""},
     {"workingdir", cat([RootDir,"/compserve"])}
    ].

%% Will only let some things run, we have a blacklisting mechanism for certain
%% dangerous commands. We will implement our own if they are still important to
%% have avaliable, like rm. See the Remove command below.
do( {run, Exec} , Options, Vars) ->
   case on_blacklist( Exec ) of
      true  -> {error, badarg};
      false -> 
           CleanExec = c(fix_vars( Exec, Vars )),
           do_exec( CleanExec, Options )
    end; 

%% Remove command will check if they want to remove files or directories, and
%% will "safely" (relative), remove them. In the case of directories we instead
%% move them to the trash bin which can be cleaned up by the administrator 
%% later.
do( {delete, RemoveObj}, Options, Vars ) ->
    case RemoveObj of
        {file, File} -> 
            CleanExec = fix_vars( cat(["rm -- ", c(File)]), Vars ),
            do_exec(CleanExec, Options);
        {dir, Dir} ->
            CleanExec = fix_vars( cat(["mv -n -- ", loc(c(Dir), Vars),
                                       " %trash%/."]), Vars ),
            do_exec(CleanExec, Options);
        all ->
            CleanExec = fix_vars( cat(["mkdir trash_%compname%; ",
                                       "mv * trash_%compname%/.; ",
                                       "mv * %trash%/."]), Vars ),
            do_exec(CleanExec, Options)
    end;

%% This is a meta-command which doesn't really touch the os, but instead
%% returns the file path of the file that needs to be added to the result
%% message.
do( {return, ReturnObj}, Options, Vars ) ->
    case ReturnObj of
        all -> 
            CleanExec = fix_vars( cat(["zip -r result_%compname%.zip *; ",
                                       "mv result_%compname%.zip ../."] ), 
                                  Vars ),
            do_exec( CleanExec, Options );
            
            %TODO: Consider other options here such as lists of files. 
        {contents, Path} ->
            CleanPath = fix_vars( loc( "%workingdir%/"++c(Path), Vars ), Vars ),
            Contents = readlines( CleanPath ),
            {mark_return, {value, Contents}};
        Path -> 
            {mark_return, fix_vars( loc( c(Path), Vars), Vars )}
    end;

%% If we don't know the Action, then error report.
do( UnknownAction, _, _ ) -> 
    ?DEBUG("Unknown action passed to action handler: ~p", [UnknownAction]),
    {error, badarg}.


%% @private
%% @doc Actually perform the request after logging. We need to wrap the result
%%   with our return of a successful "attempt".
%% @end
do_exec( Exec, Options ) ->
    ?DEBUG("STEVE IS RUNNING: [~p] with the options: ~n~p",[Exec,Options]),
    exec:run_link( Exec, Options ).


%% @hidden
%% @doc Should really be pushed to a config file for customization
on_blacklist( Exec ) ->
    [Cmd|_Args] = string:tokens( Exec, [ $\s ] ),
    lists:member( Cmd, ["rm","rmdir","chown","chmod","cd","ln","wget"] ).

%% @hidden
%% @doc Runs through the command and finds any %varname% placement holders
%%   and replaces it with the variable in the Vars list.
%% @end
fix_vars( "", _ ) -> "";
fix_vars( Cmd, Vars ) ->
    ?DEBUG("STEVE FIX VARS: ~p -> ~p",[Cmd,Vars]),
    {Front, Rest} = lists:splitwith( fun( C ) -> C/=$% end, Cmd ),
    case Rest of
        "" -> Front;
        [$%|Check] -> 
            {Var,Back} = lists:splitwith( fun(C)-> C/=$% end, Check ), 
            (case Back of 
                 "" -> Front ++ Var;
                 [$%|R] -> Front ++ replace(Var, Vars) ++ fix_vars( R, Vars )
             end);
        _ -> Front ++ fix_vars(Rest, Vars)
    end.
replace( V, VL ) -> proplists:get_value( V, VL, V ).

%% @hidden
%% @doc Character purger. If we don't like particular character's in out cmd.
c([])->[];
c([$;|R])->c(R); % NO SEMICOLONS!
c([$~|R])->c(R); % NO TILDAS!
c([A|R])->[A|c(R)].

cat([]) -> "";
cat([A|R]) ->string:concat(A, cat(R)).

%% @hidden
%% @doc Disable locations outside of current directory and subdirectory.
loc( Dir, Vars ) ->
    _WorkingDir = replace("workingdir",Vars),
    Dir. %XXX: This needs to be fixed, We need to check relative path.
         % See for a python version: http://stackoverflow.com/q/3812849

%% @hidden
%% @doc Read the contents of a file into memory.
readlines( Path ) ->
    {ok, Device} = file:open( Path, [read] ),
    try lists:reverse( get_all_lines(Device, []) )
    after file:close(Device) end.
get_all_lines( Device, Acc ) ->
    case io:get_line( Device, "" ) of
        eof -> Acc;
        Line -> get_all_lines( Device, [Line|Acc] )
    end.
