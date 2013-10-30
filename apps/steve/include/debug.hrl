-define(DEBUG_RUN, true).

-ifdef(DEBUG_RUN).
-define(DEBUG( Msg, Format ), io:fwrite(Msg++"~n", Format)).

-else.
-define(DEBUG( _, _), true).

-endif.

-define(ERROR(Section, Message),
        io:fwrite("ERR:~p:~p~n",[Section,Message])).
-define(ERROR(Section, Message, Format), 
        io:fwrite("ERR:~p:"++Message++"~n",[Section|Format])).
