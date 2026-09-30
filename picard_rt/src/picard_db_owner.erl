-module (picard_db_owner).
-behaviour (gen_server).
-export ([start_link/0]).
-export ([init/1, handle_call/3, handle_cast/2]).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  case picard_db:is_owner() of
    true -> pg:join(picard_db, self());
    false -> ok
  end,
  {ok, #{}}.

handle_call({query, Sql, Args}, _From, State) ->
  {reply, errm_sqlite:query(picard_db:db(), Sql, Args), State};
handle_call(_Req, _From, State) ->
  {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

