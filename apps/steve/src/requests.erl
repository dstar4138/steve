%%
%% There is an idea of Requests and Capability matching. Normally at work we 
%% would be able to know the forte or at least what an individual is capable of.
%% We would then be able to know whether they would be able to do something for
%% us (fulfill our Request). 
%%
%% This module attempts to take in a request structure (generic form of the 
%% Request) and the capability of the system, and unify them in a easily 
%% checkable structure that can be used later.
%%
-module(requests).

%-export([build/2, match/2]).
-compile(export_all).
-include("debug.hrl").


%%%
%%% RequestStruct is a list of tuples of the following forms:
%%%
%%% { NameOfRequestItem :: atom(),
%%%   RequiredOrNot  :: atom(),    <---- Optional, put 'required' atom if needed
%%%   PatternToMatch :: reqpat() }
%%%
%%% reqpat() :: 
%%%     [ reqpat() ] |      <-- list of possible values for it
%%%     tuple( reqpat() ) | <-- a tuple with each part a matcher
%%%     regex_string() |    <-- a regex string
%%%     preset_regex()      <-- provided atoms for regex presets.
%%%  
-type 'PVAL'() :: {'PVAL'(), 'PVAL'() } | [ 'PVAL'() ] | atom() | string().
-type 'TASK'() :: { atom(), 'PVAL'() } | {atom(), required, 'PVAL'()}.
-type 'REQUEST_DEFINITION'() :: {requests, [ 'TASK'() ]}.
-type 'REQUEST'() :: {request, ['TASK'()]}.

%%% CapabilityList is a list of capability records.
%%% {capability, RequirementMatch :: RequestStruct(),
%%%              ActionList :: [ action() ],
%%%              GlobalCapOrInstance :: global | instance
%%% }
%%% 
%%% The difference between RequirementMatch and the Request structure, is that 
%%% it can have duplicates of the tuples found in the Request structure. This
%%% is because we a capability can match multiple requests. (i.e. my ability at
%%% Python2.7 can be fulfilled if they requested "python" or "python2.7" or even
%%% "python2.*". This is a contrived example, but it makes the point.)
%%%
%%% ActionList is a list of actions() which can be defined as:
%%%
%%%     action() ::
%%%         { run, ExecutableString() }   | <-- run this command 
%%%         { return, FileDescription() } | <-- add file to list of returns
%%%         { delete, FileDescription() }   <-- rm file from system
%%% 
%%% GlobalCapOrInstance is a way for you to make it easier to list these 
%%% capabilities. All capability records marked as 'global' are concatenated and
%%% then appended to all other 'instance' capabilty records when they are being 
%%% checked for a match. (i.e. leave things like OS version and architecture 
%%% types in global.) 
%%%
-type 'ACTION'() :: { run, string()} | { return, tuple() } | {delete, tuple()}.
-type 'CAPABILITY'() :: {capability, [ 'TASK'() ], [ 'ACTION'() ]}.
-type 'CAPABILITIES'() :: [ 'CAPABILITY'() ].

%%% The CapStruct is created to make for faster pattern matching. It wraps the
%%% requirement match with its type, removes unneeded data from the matching 
%%% portion and puts actions to the back of the structure.
%%%
%%% {capstruct, MATCHES, TAG_ACTIONS}
%%%
%%% MATCHES := [ {TAG, [{ MATCHER, [CID] }]} ]
%%% MATCHER := {raw, atom()} | {re, REGEX} 
%%%                          | {list,int(), MATCHER} 
%%%                          | {tuple, int(), MATCHER}
%%%
%%% CID := int()
%%%
%%% TAG_ACTIONS := [ {CID, ACTIONS} ]
%%%
-record(capstruct, { matches = [], tagacts = [] }).


%% Builds the CapabilityStructure for matching against a request message.
-spec build( 'REQUEST_DEFINITION'(), 'CAPABILITIES'() ) -> #capstruct{}.
build( RequestStruct, CapabilityList ) ->
    {requests, TagList} = RequestStruct,
    {ok, CapStruct} = construct( CapabilityList ),
    case verify( CapStruct, TagList ) of
        ok -> {ok, CapStruct};
        {error, Err} -> {error, Err}
    end.

-spec match( #capstruct{}, 'REQUEST'() ) -> {ok, nomatch | 'CAPABILITY'()} | 
                                            {error,badcaps}.
match( CapabilityStruct, RequestMsg ) -> 
    {request, Tasks} = RequestMsg,
    {ok, Ms} = find_matches( Tasks, CapabilityStruct#capstruct.matches ),
    case Ms of
        []  -> {ok, nomatch};
        [X] -> {ok, lookup( X, CapabilityStruct )};
        _   -> {error, badcaps}
    end.


%% ===========================================================================
%% Internal Functions
%% ===========================================================================

% Builds a capstruct. See above.
construct( CapabilityList ) -> 
    {ok, Gs, Is} = gi_split( CapabilityList, [], [] ),
    {ok, Caps} = merge_globals( Gs, Is ),
    {ok, Tagged, Actions} =  tag_caps( Caps, [], [], 0 ), 
    build_capstruct( Tagged, #capstruct{tagacts=Actions} ).


gi_split( [], Gs, Is ) -> {ok, Gs, Is};
gi_split( [{_,B,global}    |R], Gs, Is ) -> gi_split( R, [B|Gs], Is );
gi_split( [{_,B,C,instance}|R], Gs, Is)  -> gi_split( R, Gs, [{B,C}|Is] ).

merge_globals( [], Is ) -> {ok, Is};
merge_globals([G|R], Is) -> merge_globals( R, lists:foldl( merge_global(G),
                                                          [], Is )).
merge_global( G ) -> 
    SG = lists:keysort(1, G),
    fun ( {ITags, IActs}, Is ) -> 
         SI = lists:keysort( 1, ITags ),
         [{lists:keymerge( 1, SI, SG ),IActs}|Is] % TAG in SI takes precidence.
    end.

% Loops through all capabilities giving them their CapID. It also breaks them
% up into a taged list of matchers and a taged list of actions.
tag_caps( [], TCs, As, _ ) -> {ok, TCs, As};
tag_caps( [{ITs,IAs}|R], TCs, As, N ) -> 
    tag_caps( R, [{N,ITs}|TCs], [{N,IAs}|As], N+1 ).

% Builds the capstruct as long as it has a tagged capability list.
build_capstruct( [], CS=#capstruct{matches=Ms} ) ->
    {ok, CS#capstruct{matches=lists:keysort(1, Ms)}};
build_capstruct( [{CID,TagList}|R], CS=#capstruct{matches=Matches} ) ->
    NewMs = lists:foldl( fun( {Tag,M}, Ms ) ->
                            keyupdate( Tag, {expand_match(M), CID}, Ms ) 
                         end, Matches, TagList ),
    build_capstruct( R, CS#capstruct{matches=NewMs} ).


% Updates a key/[value] list by appending another value for that key.
keyupdate( Key, Val, L ) -> keyupdate( Key, Val, L, [] ).
keyupdate( Key, Val, [], S ) -> [{Key, [ Val ]}|S];
keyupdate( Key, Val, [{ Key, Prev}|R], S ) -> lists:flatten([{Key,[Val|Prev]},R,S]);
keyupdate( Key, Val, [X|R], S ) -> keyupdate( Key, Val, R, [X|S] ).

% Wraps a Match with a type.
expand_match( M ) when is_atom(M) -> 
    {raw, M};
expand_match( M ) when is_tuple(M) -> 
    {tuple, tuple_size(M), lists:foldl( fun(Elem, L) ->
                                            [expand_match(Elem)|L] 
                                        end, [], tuple_to_list(M))};
expand_match( M ) when is_list(M) -> % could be re or list, so check encoding
    case io_lib:printable_unicode_list( M ) of
        false -> {list, length(M), lists:map( fun expand_match/1, M )};
        true  -> {ok, MP} = re:compile(M), {re, MP}
    end.


% Checks if capstruct has all tags required in request struct, if not, there is 
% no possible way to match. Assumes the validity of matcher as regex comparison
% is really hard.
verify( _, [] ) -> ok;
verify( C, [{_,_}|R] ) -> verify( C, R );
verify( C, [{T,required,_}|R] ) -> 
    case lists:keymember( T, 1, C#capstruct.matches ) of
        false -> 
            {error, 
             io_lib:format("Missing at least one capability matching: ~p",[T])};
        true  -> verify( C, R )
    end.
    
% Grabs the value of a Capability ID from a capstruct.
lookup( CID, #capstruct{tagacts=Ts} ) ->
    case lists:keysearch(CID, 1, Ts) of
        {value, {CID,V}} -> V;
        false -> 
           ?ERROR("requests:lookup","FOUND CID WITHOUT MATCHING TAG ACTIONS",[])
    end.

% Runs through the matcher list from a capstruct, will maintain a list of 
% possible CIDs that can take care of that particular Task list.
find_matches( Tasks, MatchList ) -> 
    {ok, find_matches( Tasks, MatchList, {sets:new(), sets:new()}) }.
find_matches( [], _, {CIDS,_} ) -> sets:to_list(CIDS);
find_matches( [{T,M}|R], Ms, C) ->
    case lists:keysearch(T,1,Ms) of
        {value,{_,Ml}} -> 
            find_matches( R, Ms, check_each_match( M, Ml, C ));
        false -> []
    end.
check_each_match( _, [], Cs ) -> Cs;
check_each_match( Match, [{M,C}|R], Cs ) ->
    case check_match( Match, M ) of
        true -> check_each_match( Match, R, add_cid( C, Cs ) );
        false -> check_each_match( Match, R, rm_cid( C, Cs ) )
    end.

% We keep a set of CIDs which match and which fail, if a CID ever failed, then
% it can never match. 
add_cid( C, D={Good, Bad} ) ->
    case sets:is_element( C, Bad ) of
        true -> D;
        false -> {sets:add_element(C,Good), Bad}
    end.
rm_cid( C, {Good, Bad} ) -> 
    {sets:del_element( C, Good ), sets:add_element( C, Bad )}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% The core of match checking, this will check whether the 
%% Requested match is equivalent to the provided match. It's written to
%% take advantage of pattern as much as possible.
check_match( M, T={raw, M} ) when is_atom(M) -> 
    ?DEBUG("atom=>( ~p , ~p )=true~n",[M,T]), true;
check_match( M, T={re, R} ) when is_list(M) ->
    ?DEBUG("re=>( ~p , ~p )=",[M,T]),
    case re:run(M,R) of
        nomatch -> 
            ?DEBUG("false~n",[]),
            false;
        {match,_} -> 
            ?DEBUG("true~n",[]),
            true % possible error, what if partial match.
    end;
check_match( M, T={tuple, N, L} ) when is_tuple(M) -> %andalso tuple_size(M) =:= N ->
    ?DEBUG("tuple=>( ~p |~p| , ~p )=",[M,tuple_size(M),T]),
    case length(lists:filter( fun ({A,B}) -> check_match(A,B) end,
                                        lists:zip(tuple_to_list(M),L) )) 
    of
        N -> ?DEBUG("true~n",[]), true;
        _ -> ?DEBUG("false~n",[]), false
    end;
check_match( M, T={list, N, L} ) when is_list(M) ->
    ?DEBUG("list=>( ~p, ~p )=",[M,T]),
    if length(M) =:= N -> % if lengths are same, then its possible to match
                case length(lists:filter( fun({A,B}) -> check_match(A,B) end,
                                            lists:zip(M,L) )) 
                of
                    N -> ?DEBUG("true~n",[]), true;
                    _ -> ?DEBUG("false~n",[]), false
                end;
        true -> % Length difference, insta-fail.
            ?DEBUG("false~n",[]), false
    end;
check_match( M, {list, _, L} ) ->
    % Semantics states that when we (capability provider) provides a list, we 
    % can match any of the listings.
    ?DEBUG("OR=>{~n",[]),
    case length( lists:filter( fun( A ) -> check_match(M, A) end, L ) ) of
        0 -> ?DEBUG("-->false~n",[]), false;
        _ -> ?DEBUG("-->true~n",[]), true
    end,
    ?DEBUG("}~n",[]);
check_match( M, T ) -> 
    ?DEBUG("FAIL=>( ~p , ~p )=false~n",[M,T]),
    false.

