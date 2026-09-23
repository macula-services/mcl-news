%%% @doc Deterministic enrichment of a parsed news item — no LLM, no network.
%%%
%%% A raw item carries a title, summary, url and the source's own categories. This
%%% adds the metadata a consumer can filter, reason on and render:
%%%
%%%   * reporting_country — WHO reported it, from the source's config (exact).
%%%   * source_type       — public broadcaster / wire / private (from config).
%%%   * topic_class+emoji  — WHAT it is about, from the feed's categories and a
%%%                          keyword sweep of title+summary (a fixed taxonomy).
%%%   * subject_country    — WHERE it is about, from a gazetteer sweep (rough: a
%%%                          substring match on country/capital/demonym names, so
%%%                          it errs toward a best guess, never a crash).
%%%
%%% Pure and total: every field has a safe default, so a bare item still enriches.
%%% This is the news analogue of the sentinel's reporting/subject-country + type
%%% enrichment on the cyber use case.
-module(enrich_item).

-export([enrich/2, reporting_name/1]).

%% @doc Merge the source's declared metadata and the derived classification into
%% the item. `Source' is #{name, lang, country, type}; missing keys default.
-spec enrich(map(), map()) -> map().
enrich(Item, Source) ->
    Repcc = lower(maps:get(country, Source, <<>>)),
    {Class, Emoji} = classify(subject_text(Item)),
    {Subcc, Subname} = subject_country(subject_text(Item)),
    Item#{source                => maps:get(name, Source, <<"unknown">>),
          lang                  => source_lang(Item, Source),
          reporting_country      => Repcc,
          reporting_country_name => reporting_name(Repcc),
          source_type            => maps:get(type, Source, <<"broadcaster">>),
          topic_class            => Class,
          emoji                  => Emoji,
          subject_country        => Subcc,
          subject_country_name   => Subname}.

%% @doc The country name for an ISO-2 code (for the reporting source). `<<>>' when
%% unknown, so a mis-configured source degrades to no name rather than a crash.
-spec reporting_name(binary()) -> binary().
reporting_name(Code) ->
    name_of(lists:search(fun({C, _N, _A}) -> C =:= Code end, gazetteer())).

name_of({value, {_C, Name, _A}}) -> Name;
name_of(false)                   -> <<>>.

%% --- classification ---

%% Everything a classifier reads: the headline, the summary, and the source's own
%% categories, lower-cased once. Categories are the feed's own hint; the keyword
%% sweep is the fallback.
subject_text(Item) ->
    Cats = lists:join(<<" ">>, maps:get(topics, Item, [])),
    lower(iolist_to_binary([maps:get(title, Item, <<>>), <<" ">>,
                            maps:get(summary, Item, <<>>), <<" ">>, Cats])).

classify(Text) ->
    pick_topic(lists:search(fun({_C, _E, Kws}) -> any_kw(Text, Kws) end, topics())).

pick_topic({value, {Class, Emoji, _Kws}}) -> {Class, Emoji};
pick_topic(false)                         -> {<<"general">>, <<"📰"/utf8>>}.

%% Priority order: the first class with a keyword hit wins, so a war story is
%% "conflict", not "politics". Emojis double as a reader's at-a-glance
%% signal and a compact cue in the headline line.
topics() ->
    [{<<"conflict">>, <<"⚔️"/utf8>>,
      [<<"war">>, <<"military">>, <<"missile">>, <<"troops">>, <<"ceasefire">>,
       <<"airstrike">>, <<"invasion">>, <<"militant">>, <<"insurgen">>, <<"combat">>,
       <<"offensive">>, <<"shelling">>]},
     {<<"justice">>, <<"⚖️"/utf8>>,
      [<<"court">>, <<"trial">>, <<"verdict">>, <<"lawsuit">>, <<"prosecut">>,
       <<"ruling">>, <<"supreme court">>, <<"indict">>, <<"sentenced">>]},
     {<<"economy">>, <<"💶"/utf8>>,
      [<<"econom">>, <<"inflation">>, <<"market">>, <<"trade">>, <<"tariff">>,
       <<"gdp">>, <<"unemploy">>, <<"central bank">>, <<"stocks">>, <<"currency">>,
       <<"budget">>, <<"recession">>]},
     {<<"climate">>, <<"🌍"/utf8>>,
      [<<"climate">>, <<"emission">>, <<"carbon">>, <<"warming">>, <<"drought">>,
       <<"wildfire">>, <<"renewable">>, <<"biodivers">>]},
     {<<"disaster">>, <<"🌊"/utf8>>,
      [<<"earthquake">>, <<"hurricane">>, <<"tsunami">>, <<"disaster">>,
       <<"explosion">>, <<"derail">>, <<"flooding">>]},
     {<<"health">>, <<"🩺"/utf8>>,
      [<<"health">>, <<"virus">>, <<"vaccine">>, <<"hospital">>, <<"disease">>,
       <<"outbreak">>, <<"pandemic">>, <<"mental health">>]},
     {<<"science">>, <<"🔬"/utf8>>,
      [<<"research">>, <<"scientist">>, <<"space">>, <<"physics">>, <<"genome">>,
       <<"quantum">>, <<"discovery">>, <<"astronom">>, <<"telescope">>]},
     {<<"tech">>, <<"💻"/utf8>>,
      [<<"technology">>, <<"software">>, <<"artificial intelligence">>,
       <<"semiconductor">>, <<"cyber">>, <<"startup">>, <<"algorithm">>]},
     {<<"culture">>, <<"🎭"/utf8>>,
      [<<"film">>, <<"music">>, <<"festival">>, <<"museum">>, <<"theatre">>,
       <<"cinema">>, <<"heritage">>, <<"literature">>]},
     {<<"sport">>, <<"⚽"/utf8>>,
      [<<"match">>, <<"tournament">>, <<"championship">>, <<"olympic">>,
       <<"league">>, <<"world cup">>, <<"grand slam">>]},
     {<<"politics">>, <<"🏛️"/utf8>>,
      [<<"election">>, <<"parliament">>, <<"minister">>, <<"government">>,
       <<"president">>, <<"senate">>, <<"coalition">>, <<"referendum">>,
       <<"policy">>, <<"diplomat">>, <<"sanction">>, <<"protest">>]}].

%% --- subject country (gazetteer sweep) ---

subject_country(Text) ->
    matched(lists:search(fun({_C, _N, Aliases}) -> any_kw(Text, Aliases) end, gazetteer())).

matched({value, {Code, Name, _A}}) -> {Code, Name};
matched(false)                     -> {<<>>, <<>>}.

%% ISO-2, display name, and match aliases (country + demonym + capital), all
%% lower-cased. A focused set: EU27 plus the countries that dominate world news.
%% Substring matching is deliberately rough (free, no model) — a best guess for
%% the public map, never authoritative.
gazetteer() ->
    [{<<"ua">>, <<"Ukraine">>, [<<"ukrain">>, <<"kyiv">>, <<"kiev">>]},
     {<<"ru">>, <<"Russia">>, [<<"russia">>, <<"russian">>, <<"moscow">>, <<"kremlin">>]},
     {<<"us">>, <<"United States">>,
      [<<"united states">>, <<" u.s.">>, <<" us ">>, <<"american">>, <<"washington">>,
       <<"white house">>, <<"pentagon">>]},
     {<<"gb">>, <<"United Kingdom">>,
      [<<"britain">>, <<"british">>, <<"london">>, <<"united kingdom">>, <<" uk ">>]},
     {<<"il">>, <<"Israel">>, [<<"israel">>, <<"israeli">>, <<"jerusalem">>, <<"tel aviv">>]},
     {<<"ps">>, <<"Palestine">>, [<<"palestin">>, <<"gaza">>, <<"west bank">>, <<"hamas">>]},
     {<<"ir">>, <<"Iran">>, [<<"iran">>, <<"iranian">>, <<"tehran">>, <<"teheran">>]},
     {<<"cn">>, <<"China">>, [<<"china">>, <<"chinese">>, <<"beijing">>]},
     {<<"in">>, <<"India">>, [<<"india">>, <<"indian">>, <<"new delhi">>]},
     {<<"tr">>, <<"Turkey">>, [<<"turkey">>, <<"turkish">>, <<"ankara">>, <<"istanbul">>]},
     {<<"sy">>, <<"Syria">>, [<<"syria">>, <<"syrian">>, <<"damascus">>]},
     {<<"fr">>, <<"France">>, [<<"france">>, <<"french">>, <<"paris">>]},
     {<<"de">>, <<"Germany">>, [<<"germany">>, <<"german">>, <<"berlin">>]},
     {<<"be">>, <<"Belgium">>, [<<"belgium">>, <<"belgian">>, <<"brussels">>]},
     {<<"nl">>, <<"Netherlands">>, [<<"netherlands">>, <<"dutch">>, <<"amsterdam">>, <<"the hague">>]},
     {<<"it">>, <<"Italy">>, [<<"italy">>, <<"italian">>, <<"rome">>]},
     {<<"es">>, <<"Spain">>, [<<"spain">>, <<"spanish">>, <<"madrid">>]},
     {<<"pt">>, <<"Portugal">>, [<<"portugal">>, <<"portuguese">>, <<"lisbon">>]},
     {<<"pl">>, <<"Poland">>, [<<"poland">>, <<"polish">>, <<"warsaw">>]},
     {<<"at">>, <<"Austria">>, [<<"austria">>, <<"austrian">>, <<"vienna">>]},
     {<<"gr">>, <<"Greece">>, [<<"greece">>, <<"greek">>, <<"athens">>]},
     {<<"se">>, <<"Sweden">>, [<<"sweden">>, <<"swedish">>, <<"stockholm">>]},
     {<<"fi">>, <<"Finland">>, [<<"finland">>, <<"finnish">>, <<"helsinki">>]},
     {<<"ie">>, <<"Ireland">>, [<<"ireland">>, <<"irish">>, <<"dublin">>]},
     {<<"hu">>, <<"Hungary">>, [<<"hungary">>, <<"hungarian">>, <<"budapest">>]},
     {<<"cz">>, <<"Czechia">>, [<<"czech">>, <<"prague">>]},
     {<<"ro">>, <<"Romania">>, [<<"romania">>, <<"romanian">>, <<"bucharest">>]},
     {<<"dk">>, <<"Denmark">>, [<<"denmark">>, <<"danish">>, <<"copenhagen">>]},
     {<<"no">>, <<"Norway">>, [<<"norway">>, <<"norwegian">>, <<"oslo">>]},
     {<<"ch">>, <<"Switzerland">>, [<<"switzerland">>, <<"swiss">>, <<"geneva">>, <<"zurich">>]},
     {<<"eg">>, <<"Egypt">>, [<<"egypt">>, <<"egyptian">>, <<"cairo">>]},
     {<<"et">>, <<"Ethiopia">>, [<<"ethiopia">>, <<"ethiopian">>, <<"addis ababa">>]},
     {<<"za">>, <<"South Africa">>, [<<"south africa">>, <<"johannesburg">>, <<"pretoria">>]},
     {<<"br">>, <<"Brazil">>, [<<"brazil">>, <<"brazilian">>, <<"brasilia">>]},
     {<<"jp">>, <<"Japan">>, [<<"japan">>, <<"japanese">>, <<"tokyo">>]},
     {<<"kr">>, <<"South Korea">>, [<<"south korea">>, <<"seoul">>]},
     {<<"kp">>, <<"North Korea">>, [<<"north korea">>, <<"pyongyang">>]}].

%% --- helpers ---

source_lang(Item, Source) ->
    lang(maps:get(lang, Item, <<>>), Source).

lang(<<>>, Source) -> maps:get(lang, Source, <<"en">>);
lang(L, _Source)   -> L.

any_kw(Text, Kws) -> lists:any(fun(K) -> contains(Text, K) end, Kws).

contains(_Text, <<>>) -> false;
contains(Text, K)     -> binary:match(Text, K) =/= nomatch.

lower(Bin) when is_binary(Bin) -> string:lowercase(Bin);
lower(_NotBin)                 -> <<>>.
