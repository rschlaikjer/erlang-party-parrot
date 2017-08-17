-module(party_bot).
-compile([{parse_transform, lager_transform}]).
-behaviour(gen_server).

-define(SLACK_HOST, "slack.com").
-define(SLACK_RTM_START_URI, <<"/api/rtm.start">>).
-define(COOLDOWN_SECS, 30).

-define(PARROTS, [
    <<"aussie_parrot">>, <<"explodyparrot">>, <<"fieri_parrot">>,
    <<"fiesta_parrot">>, <<"mustacheparrot">>, <<"partyparrot">>,
    <<"ship_it_parrot">>, <<"ski_parrot">>, <<"social_parrot">>,
    <<"witness_protection_parrot">>, <<"beretparrot">>, <<"bananaparrot">>,
    <<"reverseaussiecongaparrot">>, <<"aussiecongaparrot">>,
    <<"blondesassyparrot">>, <<"bluescluesparrot">>, <<"boredparrot">>,
    <<"chillparrot">>, <<"christmasparrot">>, <<"coffeeparrot">>,
    <<"confusedparrot">>, <<"darkbeerparrot">>, <<"dealwithitparrot">>,
    <<"dreidelparrot">>, <<"fastparrot">>, <<"fidgetparrot">>,
    <<"gentlemanparrot">>, <<"gothparrot">>, <<"halalparrot">>,
    <<"hamburgerparrot">>, <<"harrypotterparrot">>, <<"ice-cream-parrot">>,
    <<"loveparrot">>, <<"margaritaparrot">>, <<"matrixparrot">>,
    <<"middleparrot">>, <<"moonwalkingparrot">>, <<"nyanparrot">>,
    <<"oldtimeyparrot">>, <<"papalparrot">>, <<"parrotbeer">>,
    <<"parrotcop">>, <<"parrotsleep">>, <<"parrotwave1">>,
    <<"parrotwave2">>, <<"parrotwave3">>, <<"parrotwave4">>,
    <<"parrotwave5">>, <<"parrotwave6">>, <<"parrotwave7">>,
    <<"pizzaparrot">>, <<"prideparrot">>, <<"rightparrot">>,
    <<"sadparrot">>, <<"sassyparrot">>, <<"scienceparrot">>,
    <<"slowparrot">>, <<"stableparrot">>, <<"stalkerparrot">>,
    <<"thumbsupparrot">>, <<"tripletsparrot">>, <<"twinsparrot">>,
    <<"upvotepartyparrot">>
]).

%% Public API
-export([connect/1]).

%% Supervisor callback
-export([start_link/1]).
%%
%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    slack_token :: binary(),
    gun ::any(),
    whoami :: binary(),
    cooldowns :: map()
}).

start_link(SlackToken) ->
    gen_server:start_link(?MODULE, [SlackToken], []).

init([SlackToken]) ->
    State = #state{
           slack_token=SlackToken,
           cooldowns=#{}
    },
    gen_server:cast(self(), reconnect),
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:info("Unexpected call ~p~n", [Request]),
    {noreply, State}.

handle_cast(reconnect, State) ->
    % Reset the gun connection
    {ok, State1} = reconnect_websocket(State),
    {noreply, State1};
handle_cast({add_reaction, Channel, Ts, React}, State) ->
    spawn(fun() -> add_reaction(State, Channel, Ts, React) end),
    {noreply, State};
handle_cast(Msg, State) ->
    lager:info("Unexpected cast ~p~n", [Msg]),
    {noreply, State}.

handle_info({gun_ws, _Gun, Message}, State) ->
    State1 = handle_slack_ws_message(State, Message),
    {noreply, State1};
handle_info({gun_down, Gun, _Proto, _Reason, [], []}, State) ->
    gun:close(Gun),
    gen_server:cast(self(), reconnect),
    {noreply, State};
handle_info({gun_ws_upgrade, _Gun, ok, Headers}, State) ->
    lager:info(
        "Websocket upgrade complete via ~s~n",
        [proplists:get_value(<<"x-via">>, Headers)]
    ),
    {noreply, State};
handle_info(Info, State) ->
    lager:info("Unexpected info ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(OldVsn, State, _Extra) ->
    lager:info("~p updated from vsn ~p", [?MODULE, OldVsn]),
    {ok, State}.

reconnect_delayed(Time) ->
    Self = self(),
    timer:apply_after(Time, gen_server, cast, [Self, reconnect]).

% Convenience method to start the party
connect(SlackToken) when is_binary(SlackToken) ->
    case supervisor:start_child(party_bot_sup, [SlackToken]) of
        OK = {ok, _} ->
            OK;
        StartError ->
            StartError
    end.

reconnect_websocket(State=#state{slack_token=Token}) ->
    {ok, RtmStartJson} = request_rtm_start(Token),
    case proplists:get_value(<<"ok">>, RtmStartJson) of
        false ->
            lager:info("Got bad start json: ~p~n", [RtmStartJson]),
            reconnect_delayed(60000),
            {ok, State};
        true ->
            {<<"self">>, Self} = proplists:lookup(<<"self">>, RtmStartJson),
            {<<"id">>, Id} = proplists:lookup(<<"id">>, Self),
            {<<"url">>, WsUrl}  = proplists:lookup(<<"url">>, RtmStartJson),
            {ok, Gun, _StreamRef} = connect_websocket(WsUrl),
            {ok, State#state{
                gun=Gun,
                whoami=Id
            }}
    end.

connect_websocket(WsUri) ->
    {ok, {wss, [], Host, 443, Fragment, []}} = http_uri:parse(
        erlang:binary_to_list(WsUri),
        [{scheme_defaults, [{wss, 443}]}]
    ),
    {ok, Pid} = gun:open(Host, 443, #{protocols => [http]}),
    {ok, _} = gun:await_up(Pid),
    StreamRef = gun:ws_upgrade(Pid, Fragment),
    {ok, Pid, StreamRef}.

%% Send a request to the RTM start API endpoint
request_rtm_start(Token) ->
    {ok, Gun} = gun:open(?SLACK_HOST, 443, #{protocols => [http]}),
    {ok, _} = gun:await_up(Gun),
    Path = <<?SLACK_RTM_START_URI/binary, "?token=", Token/binary>>,
    StreamRef = gun:get(Gun, Path),
    Result = case gun:await(Gun, StreamRef) of
          {response, fin, _Status, _ResponseHeaders} ->
            {error, no_websocket};
          {response, nofin, Status, ResponseHeaders} ->
              {ok, ResponseBody} = gun:await_body(Gun, StreamRef),
              case Status of
                  200 ->
                      JsonBody = jsx:decode(ResponseBody),
                      {ok, JsonBody};
                  _ ->
                      {error, {Status, ResponseBody, ResponseHeaders}}
              end;
          {error, timeout} ->
                {error, timeout};
          Anything ->
              {error, Anything}
             end,
    gun:shutdown(Gun),
    Result.

%% Decode a JSON payload from slack, then call the appropriate handler
handle_slack_ws_message(State, {text, Json}) ->
    WsPayload = jsx:decode(Json),
    handle_slack_payload(State, proplists:get_value(<<"type">>, WsPayload), WsPayload).

%% Handlers for each of the slack message types
handle_slack_payload(State, <<"reaction_added">>, Payload) ->
    Item = proplists:get_value(<<"item">>, Payload),
    MessageTs = proplists:get_value(<<"ts">>, Item),
    User = proplists:get_value(<<"user">>, Payload),
    Channel = proplists:get_value(<<"channel">>, Item),
    Reaction = proplists:get_value(<<"reaction">>, Payload),
    IsParrot = is_parrot(Reaction),
    IsDifferentUser = State#state.whoami /= User,
    IsNotOnCooldown = os:system_time(second) - maps:get(Channel, State#state.cooldowns, 0) > ?COOLDOWN_SECS,
    case IsParrot and IsDifferentUser and IsNotOnCooldown of
        true ->
            add_parrots(Channel, MessageTs);
        false ->
            ok
    end,
    State#state{cooldowns=maps:put(Channel, os:system_time(second), State#state.cooldowns)};
handle_slack_payload(State, <<"message">>, Payload) ->
    MessageTs = proplists:get_value(<<"ts">>, Payload),
    User = proplists:get_value(<<"user">>, Payload),
    Channel = proplists:get_value(<<"channel">>, Payload),
    Text = proplists:get_value(<<"text">>, Payload),
    lager:info("Message: ~p~n", [Text]),
    IsParrot = is_parrot(binary:replace(Text, <<":">>, <<"">>, [global])),
    IsDifferentUser = State#state.whoami /= User,
    case IsParrot and IsDifferentUser of
        true ->
            add_parrots(Channel, MessageTs);
        false ->
            ok
    end,
    State;
handle_slack_payload(State, _Type, _Payload) ->
    % lager:info("Ignoring payload type ~p: ~p ~n", [Type, Payload]),
    State.

is_parrot(Reaction) ->
    lists:any(
      fun (Parrot) -> Reaction == Parrot end,
      ?PARROTS
    ).

rand_parrots(Num) ->
    rand_parrots(Num, [], ?PARROTS).

rand_parrots(_Num, Parrots, []) ->
    Parrots;
rand_parrots(0, Parrots, _PossParrots) ->
    Parrots;
rand_parrots(Num, Parrots, PossibleParrots) ->
    Parrot = lists:nth(rand:uniform(length(PossibleParrots)), PossibleParrots),
    Rest = lists:filter(
        fun (P) -> P /= Parrot end,
        PossibleParrots
    ),
    rand_parrots(Num - 1, [Parrot|Parrots], Rest).

add_parrots(Channel, MessageTs) ->
    lager:info("React in ~s~n", [Channel]),
    lists:map(
      fun (Parrot) ->
              gen_server:cast(
                self(),
                {add_reaction, Channel, MessageTs, Parrot}
              )
      end,
      rand_parrots(10)
    ),
    ok.

add_reaction(State, Channel, MessageTs, Reaction) ->
    Url = io_lib:format(
        "https://slack.com/api/reactions.add?token=~s&name=~s&channel=~s&timestamp=~s",
        [State#state.slack_token, Reaction, Channel, MessageTs]
    ),
    case httpc:request(Url) of
        {ok, _} -> ok;
        {error, Reason} ->
            lager:error("Failed to add reaction: ~p~n", [Reason]),
            ok
    end.
