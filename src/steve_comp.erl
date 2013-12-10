-module(steve_comp).
-behaviour(gen_fsm).

-include("debug.hrl").

%% API
-export([start_link/3]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).
%% Computation States.
-export([ 'ARCHIVE_WAIT'/2, 'RUNNING'/2, 'WRAPUP'/2 ]).
-export([do_action/4]). %PRIVATE
-define(COMPS, comps_pg).

%% TODO: Following should probably change based on computation ID.
-define(WORKSPACE, steve_util:getrootdir()++"/compserve"). 
-define(EXEC_OPTS, [ monitor, {stdout,self()}, {cd, ?WORKSPACE}]).

%% Computation Information.
-record(state, { compID, actions=[], 
                 cur_action=nil, sub_vars=[], 
                 returns=[], value=nil }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(ComputationID, ActionList, HangForFile) ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [ComputationID,
                                                   ActionList,
                                                   HangForFile], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([ComputationID,ActionList,HangForFile]) ->
    process_flag( trap_exit, true),
    InternalState = setup_state( ComputationID, ActionList ),
    if HangForFile -> {ok, 'ARCHIVE_WAIT', InternalState};
       true -> 
           Ret = start_next( InternalState ), 
           ?DEBUG("RETURN FROM START_NEXT: ~p",[Ret]),
           {S,I} = Ret,
           {ok, S, I}
    end.

%%% =====================================================================
%%% ========================    STATES   ================================
%%% =====================================================================
'ARCHIVE_WAIT'( Event, State ) -> 
    %We ignore all event signals unless it's shutdown.
    case Event of 
        shutdown -> 
            {stop, normal, State}; 
        _ -> 
            {next_state, 'ARCHIVE_WAIT', State}
    end.

'RUNNING'( Event, State ) ->
    case Event of
        {action, Status} -> 
            {NewStateName, NewState} = process_action( Status, State ),
            {next_state, NewStateName, NewState};
        shutdown ->
            stop_actions( State ),
            {stop, normal};
        _ -> 
            report_unknown(Event, State),
            {next_state, 'RUNNING', State}
    end.

'WRAPUP'(Event, State) ->
    case Event of
        shutdown -> 
            hang_for_wrapup( State ),
            {stop, normal};
        _ -> 
            {next_state, 'WRAPUP', State}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event( Event, StateName, State) ->
    {stop, {StateName, undefined_event, Event}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {stop, Reason, NewState} 
%% @end
%%--------------------------------------------------------------------
handle_sync_event( Event, _From, StateName, State) ->
    {stop, {StateName, undefined_event, Event}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info( {pg_message, _From, ?COMPS, GroupMsg}, StateName, State ) ->
    handle_group_msg( GroupMsg, StateName, State );
handle_info( Info, StateName, State) ->
    ?DEBUG("Unknown info message: ~p",[Info]),
    {next_state, StateName, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. 
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) -> ok.

%%--------------------------------------------------------------------
%% @private
%% @doc Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

construct_workspace( State ) ->
    steve_action:start(),
    Args = update_args( steve_action:default_vars(), State ),
    steve_action:do({run, "mkdir %workingdir%"}, ?EXEC_OPTS, Args ),
    steve_action:do({run, "cp %compname%.zip %workingdir%/."}, ?EXEC_OPTS, Args ).

setup_state( ComputationID, ActionList ) ->
    #state{ compID = ComputationID,
            actions = ActionList,
            cur_action = nil,
            returns=[],
            value=nil
          }.

%% @hidden
%% @doc Handle group messages from steve_comp_sup api.
handle_group_msg( {archive_finished, CompID}, 'ARCHIVE_WAIT', 
                   #state{compID = CompID} = State ) ->
    construct_workspace( State ),
    {S,I} = start_next( State ),
    {next_state, S, I};
handle_group_msg( Unknown, StateName, State ) ->
    ?DEBUG("Unknown Group Message: ~p", [Unknown]),
    {next_state, StateName, State}.

%% @hidden
%% @doc This reacts to the status of an action that just finished. If it
%%   was the last one then we can move to 'WRAPUP'. Otherwise, progress
%%   to the next action and update state.
%% @end  
process_action( {error, Reason}, 
                #state{compID=ID, cur_action={A,_}} = State ) ->
    ?ERROR("steve_comp:process_action",
           "Action(~p) errored out: ~p.",[A,Reason]),
    finished_with_error( ID, Reason ),
    gen_fsm:send_event(self(), shutdown),
    {'WRAPUP', State}; 
process_action( {return, Val}, State )-> 
    NewState = update_return( Val, State ),
    start_next( NewState );
process_action( {finished, Ret}, #state{cur_action={A,_}} = State ) -> 
    ?DEBUG("steve_comp:process_action"
           "Action(~p): finished with status: ~p", [A,Ret]),
    start_next(State);
process_action( {stdout, Data}, #state{cur_action={A,_}} = State) ->
    ?DEBUG("steve_comp:process_action"
           "[~p]> Recieved out: ~p",[A,Data]),
    {'RUNNING',State};
process_action( _Action, State ) -> {'RUNNING', State}.

start_next( #state{ compID=CompID, actions=As } = State ) ->
    case As of
        [] -> 
            finished( CompID, State ),
            {'WRAPUP', State};
        [Next|Rest] ->
            {ok, Handle} = run_action(Next, State),
            {'RUNNING', State#state{actions=Rest, cur_action={Next,Handle}}}
    end. 
            
update_return( {value, Data}, #state{value=Curr} = State ) ->
    case Curr of
        nil -> State#state{value=Data};
        _   -> State#state{ value = Curr++Data}
    end;
update_return( Path, #state{returns=Ps} =State ) ->
    State#state{returns=[Path|Ps]}.


%% @hidden
%% @doc If there are any actions running request them be killed. We may want
%%   to log about it here.
%% @end  
stop_actions( #state{ cur_action = Action } = _State ) -> 
    case Action of 
        nil -> ok;
        _ -> kill( Action )
    end.

%% @hidden
%% @doc Report that we have no idea what this event is.
report_unknown( _Event, _State) -> ok. %TODO: This should probably change based on STATE.

%% @hidden
%% @doc Waits until the current_actions being performed are finished. This
%%   Is important for the stability of the system.
%% @end  
hang_for_wrapup( _State ) -> ok. %TODO: Will need to access steve_action internals.

%% @hidden
%% @doc Yeah I'm hardcore like that.
kill( {_,Pid} ) -> Pid!kill, ok.

%% @hidden
%% @doc Spawns a linked watcher thread that will listen for events and 
%%   send them back to the FSM.
%% @end  
run_action( Action, State ) -> 
    Opts = update_opts( ?EXEC_OPTS, State ),
    Args = update_args( steve_action:default_vars(), State ),
    Pid = spawn_link( steve_comp, do_action, [self(), Action, Opts, Args] ),
    {ok, Pid}.

%% @hidden
%% @doc A thread function which will execute the action and alert the FSM
%%   if it returns immediately, or will start the watch_loop.
do_action( Master, Action, Opts, Args ) ->
    process_flag( trap_exit, true ),
    steve_action:start(),
    case steve_action:do( Action, Opts, Args ) of
        {error, Reason} -> 
            gen_fsm:send_event(Master, {action, {error, Reason}});
        {mark_return, Val} ->
            gen_fsm:send_event(Master, {action, {return, Val}});
        {ok, Pid, _OSPid} ->
            watch_loop( Master, Pid );
        {ok, Output } -> %not expected
            ?DEBUG("Got output from action ~p => ~p",[Action, Output]);
        Unknown ->
            ?DEBUG("Unknown return value from steve_action:do(~p) = ~p",
                   [Action, Unknown])
    end.
watch_loop( Master, Pid ) ->
    receive
        kill -> steve_action:kill( Pid );
        {'DOWN',_,process,_,Status} ->
            gen_fsm:send_event(Master, {action, {finished, Status}});
        {stdout, _, Data} ->
            gen_fsm:send_event(Master, {action, {stdout, Data}}),
            watch_loop( Master, Pid );
        {'EXIT', _, Status} ->
            gen_fsm:send_event( Master, {action, {finished, Status}});
        Msg ->
            ?DEBUG("Got unknown message to watch loop: ~p",[Msg]),
            watch_loop( Master, Pid)
    end.

%% @hidden
%% @doc Ammends the State with the current state of the system.
update_args( Args, #state{compID=ID} ) ->
    EID = erlang:binary_to_list(capi:uuid_encode(ID)),
    A = lists:keyreplace("compname",1,Args,{"compname",EID}),
    lists:keyreplace("workingdir",1,A,{"workingdir",?WORKSPACE++"/"++EID}).

%% @hidden
%% @doc Ammends the Options with the current state of the system.
update_opts( Opts, #state{compID=ID} ) ->
   EID = erlang:binary_to_list(capi:uuid_encode(ID)),
   lists:keyreplace(cd,1,Opts,{cd,?WORKSPACE++"/"++EID}). 


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% System Wide Result Updating.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
finished( CompID, #state{ value=V } = State) ->
    case V of
        nil -> wrapup_returns( CompID, State );
        _   ->
            save_value( CompID, V ),
            wrapup_returns( CompID, State )
    end,
    steve_state:computation_alert(finished, CompID),
    gen_fsm:send_event(self(), shutdown).

%% TODO: Save the error as the value in the Value section, then replicate 
%% result    
finished_with_error( _CompID, _Error ) -> ok.

%% TODO: Save the value in the db for replication
save_value( _CompID, _V ) -> ok.

%% TODO: Wrap up the tagged return files.
wrapup_returns( _CompID, #state{returns=_R} ) -> ok.
 
