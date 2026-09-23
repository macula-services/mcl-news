%%% @doc The news sensor's public contract: one fact, and nothing else leaves.
%%%
%%%   news_item_reported_v1   a source published an item this sensor had not
%%%                           reported before
%%%
%%% The topic is a canonical macula app fact owned by org `mcl-news', app
%%% `news', domain `wire', for example
%%% `io.macula/mcl-news/news/wire/news_item_reported_v1'. The org segment is the
%%% schema owner and is fixed here, not deploy config.
%%%
%%% ONE TOPIC, NOT A FAN-OUT. The item's category, reporting country and source
%%% type are payload fields a consumer filters on. The service this replaces
%%% also published every item to one sub-topic per axis value so each society
%%% mind could subscribe to a slice; no consumer of those exists, and values
%%% belong in the payload, not in topic names.
%%%
%%% WHO REPORTED IT IS NOT IN THE PAYLOAD. macula delivers every event with the
%%% publisher its link verified, which is this sensor's stored node identity.
%%%
%%% Every string is `{text, Bin}' (CBOR text), so consumers outside the BEAM get
%%% strings and not hex. `body' is the readable headline line a consumer that
%%% reasons over text (an agent, a mind) is handed as-is.
-module(mcl_news_facts).

-export([report/1, topic/1, fact/2, realm_name/0, check_realm_name/0, check_realm_name/2]).

-define(APP, mcl_news).
-define(SUMMARY_MAX, 600).
-define(TITLE_MAX, 300).
-define(TEXT_FIELDS, [{item_id, <<>>}, {source, <<"unknown">>}, {url, <<>>},
                      {image_url, <<>>}, {lang, <<"en">>}, {topic_class, <<"general">>},
                      {emoji, <<"📰"/utf8>>}, {reporting_country, <<>>},
                      {reporting_country_name, <<>>}, {subject_country, <<>>},
                      {subject_country_name, <<>>}, {source_type, <<"broadcaster">>}]).

%% @doc Publish one enriched item and answer how it went. Synchronous, so the
%% sensor marks an item reported only once it was: a dark mesh or a refused
%% publish answers an error, and the item is tried again on the next poll.
-spec report(map()) -> ok | {error, term()}.
report(Item) ->
    Fact = fact(Item, erlang:system_time(millisecond)),
    mcl_om_pubsub:publish(topic(realm_name()), Fact, #{mode => sync}).

-spec topic(binary()) -> binary().
topic(RealmName) ->
    macula_topic:app_fact(RealmName, <<"mcl-news">>, <<"news">>, <<"wire">>,
                          <<"news_item_reported">>, 1).

%% @doc The fact for one parsed and enriched item, fetched at `FetchedAt' (ms).
-spec fact(map(), integer()) -> map().
fact(Item, FetchedAt) ->
    Title = clip(maps:get(title, Item, <<>>), ?TITLE_MAX),
    Summary = clip(maps:get(summary, Item, <<>>), ?SUMMARY_MAX),
    Text = maps:from_list([{K, {text, text(maps:get(K, Item, D))}} || {K, D} <- ?TEXT_FIELDS]),
    Text#{title => {text, Title},
          summary => {text, Summary},
          topics => [{text, T} || T <- maps:get(topics, Item, []), is_binary(T)],
          published_at => integer(maps:get(published_at, Item, 0)),
          fetched_at => FetchedAt,
          body => {text, body(Item, Title, Summary)}}.

%% @doc The realm name the topic carries, from `MCL_REALM_NAME'.
-spec realm_name() -> binary().
realm_name() ->
    named(application:get_env(?APP, realm_name, undefined)).

named(Name) when is_list(Name), Name =/= "" -> unicode:characters_to_binary(Name);
named(Name) when is_binary(Name), Name =/= <<>> -> Name;
named(_Unset) -> error({mcl_news_realm_name_unset, realm_name}).

%% @doc Refuse to start when the realm name is not the realm the pool publishes
%% in: the facts would go where nobody subscribed, and a sensor reporting into
%% nothing looks exactly like a quiet news day.
-spec check_realm_name() -> ok.
check_realm_name() ->
    configured(realm_name(), mcl_om:realm()).

configured(Name, {ok, Tag}) -> check_realm_name(Name, Tag);
configured(Name, Other) -> error({mcl_news_realm_unset, Name, Other}).

%% The topic is built here too: a name that hashes right but is not a valid
%% topic segment would pass the hash and then fail every report.
-spec check_realm_name(binary(), binary()) -> ok.
check_realm_name(Name, Tag) ->
    _ = topic(Name),
    matched(crypto:hash(sha256, Name) =:= Tag, Name, Tag).

matched(true, _Name, _Tag) -> ok;
matched(false, Name, Tag) -> error({mcl_news_realm_name_mismatch, Name, Tag}).

%%------------------------------------------------------------------------------

%% A compact, readable headline line, led by the topic emoji and class, tailed
%% by the source and, when the gazetteer placed the story, its subject country.
body(Item, Title, Summary) ->
    Emoji = text(maps:get(emoji, Item, <<"📰"/utf8>>)),
    Class = text(maps:get(topic_class, Item, <<"general">>)),
    Source = text(maps:get(source, Item, <<"unknown">>)),
    <<"[NEWS] ", Emoji/binary, " [", Class/binary, "] ", Title/binary,
      (dash(Summary))/binary, " (", Source/binary,
      (about(text(maps:get(subject_country_name, Item, <<>>))))/binary, ")">>.

dash(<<>>) -> <<>>;
dash(Summary) -> <<" — "/utf8, Summary/binary>>.

about(<<>>) -> <<>>;
about(Name) -> <<", about ", Name/binary>>.

text(Bin) when is_binary(Bin) -> Bin;
text(_NotText) -> <<>>.

integer(N) when is_integer(N) -> N;
integer(_NotAnInteger) -> 0.

%% Bound to N graphemes, with an ellipsis when clipped, so multibyte text is
%% never cut mid-character.
clip(Bin, Max) when is_binary(Bin) -> clip_len(Bin, string:length(Bin), Max);
clip(_NotBin, _Max) -> <<>>.

clip_len(Bin, Len, Max) when Len =< Max -> Bin;
clip_len(Bin, _Len, Max) -> <<(string:slice(Bin, 0, Max))/binary, "…"/utf8>>.
