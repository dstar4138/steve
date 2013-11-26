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
-type 'ACTION'() :: { run, string() } 
                  | { return, tuple() } 
                  | { delete, tuple() }.

-type 'VISABILITY'() :: global | instance.

-type 'CAPABILITY'() :: {capability, [ 'TASK'() ], 
                                     [ 'ACTION'() ], 
                                     'VISABILITY'() }.

-type 'CAPABILITIES'() :: [ 'CAPABILITY'() ].
