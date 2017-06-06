-ifdef(debug).

-define(DEBUG(FORMAT, DATA),
        ct:pal("~w(~B): " ++ (FORMAT), [?MODULE, ?LINE | DATA])).
-define(DEBUG(FORMAT), ?DEBUG(FORMAT, [])).

-else.

-define(DEBUG(FORMAT, DATA), (false andalso (DATA) orelse ok)).
-define(DEBUG(FORMAT), ok).

-endif.
