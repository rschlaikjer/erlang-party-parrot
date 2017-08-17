-module(party_bot_app).
-compile([{parse_transform, lager_transform}]).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Sup = party_bot_sup:start_link(),
    start_the_party(),
    Sup.

start_the_party() ->
    {ok, SlackToken} = application:get_env(party_bot, slack_token),
    party_bot:connect(SlackToken).

stop(State) ->
    ok.
