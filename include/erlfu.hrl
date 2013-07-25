-define(is_future(F), is_record(F, future)).
-define(is_futurable(F), (?is_future(F) orelse is_function(F, 0))).

-define(is_realized(F), (?is_future(F)
                         andalso (F#future.proc == undefined)
                         andalso (F#future.ref == undefined))).
-opaque future() :: tuple().
%% -type future() :: #future{}.
-type future_res() :: {'value', term()} |
                      {'error', {atom(), term(), list(term())}}.
-opaque future_attachment() :: {reference(), reference()}.


-record(future, {proc        :: gcproc:gcproc(),
                 ref         :: reference(),
                 result      :: 'undefined' | future_res()}).
