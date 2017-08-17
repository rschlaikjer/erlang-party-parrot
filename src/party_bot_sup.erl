%% @private
-module(party_bot_sup).
-behaviour(supervisor).

%% API.
-export([start_link/0]).

%% supervisor.
-export([init/1]).

-define(SUPERVISOR, ?MODULE).

%% API.

-spec start_link() -> {ok, pid()}.
start_link() ->
	supervisor:start_link({local, ?SUPERVISOR}, ?MODULE, []).

%% supervisor.

init([]) ->
	Procs = [{party_bot, {party_bot, start_link, []},
		transient, 5000, worker, [party_bot]}],
	{ok, {{simple_one_for_one, 10, 10}, Procs}}.
