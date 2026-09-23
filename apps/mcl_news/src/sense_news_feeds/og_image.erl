%%% @doc The publisher's own picture for an article, when the feed omitted it.
%%%
%%% Measured 2026-09-03 on the live record: only 1 stimulus in 10 carried a
%%% picture, although 26 of the 47 configured sources are capable of putting
%%% one in their feed. Most items from an image-capable source still arrive
%%% without one, because the picture lives on the article page and not in
%%% the RSS item.
%%%
%%% `<meta property="og:image">` is that picture: the image the publisher
%%% CHOSE for this exact article, declared in their own page for exactly
%%% this purpose. Reading it is still the publisher offering it, from a
%%% different part of their own site.
%%%
%%% == Why not an image search ==
%%%
%%% Because the rule is about consent, not bytes. A feed image is an offer;
%%% a search result is a picture from a publisher who chose not to make one.
%%% And a search is bound to a NAME, so it can attach the wrong man's
%%% photograph to "Businessman acquitted of journalist's murder", which is
%%% in this record right now. `og:image' is bound to the URL, so the worst
%%% it can be wrong about is the article it already is.
%%%
%%% == Bounded, polite, and silent on failure ==
%%%
%%% Only for items that have no picture; a short timeout; a Range request so
%%% a publisher usually sends a few kilobytes rather than a whole page; a
%%% hard cap on what is read even when Range is ignored; and any failure at
%%% all yields no image. An item without a picture renders correctly, so
%%% there is nothing here worth a retry, a queue, or a log line per item.
-module(og_image).

-export([fill/1, of_html/1, absolute/2]).

%% og:image lives in <head>, so the first bytes are all that is needed. A
%% publisher that ignores Range sends the whole page and we stop reading at
%% the cap rather than pull a megabyte of article for one meta tag.
-define(HEAD_BYTES, 65536).
-define(TIMEOUT_MS, 6000).
-define(CONNECT_TIMEOUT_MS, 4000).
-define(UA, "mcl-news/0.1 (+https://github.com/macula-services/mcl-news)").

%% @doc Fill in `image_url' from the article page, if it is missing.
%%
%% Returns the item unchanged on absolutely any failure. This runs inside the
%% poll loop, and a sensor that stops sensing because a publisher's TLS
%% expired would be a far worse outcome than a card with no picture.
-spec fill(map()) -> map().
fill(Item) when is_map(Item) ->
    needed(mget(image_url, Item), mget(url, Item), Item);
fill(Item) ->
    Item.

needed(Image, _Url, Item) when is_binary(Image), Image =/= <<>> ->
    %% The feed already gave us the publisher's picture. Never second-guess it.
    Item;
needed(_Missing, Url, Item) when is_binary(Url), Url =/= <<>> ->
    found(catch of_html(fetch(Url)), Url, Item);
needed(_Missing, _NoUrl, Item) ->
    Item.

found(Image, Url, Item) when is_binary(Image), Image =/= <<>> ->
    resolved(absolute(Image, Url), Item);
found(_Nothing, _Url, Item) ->
    Item.

resolved(<<>>, Item)  -> Item;
resolved(Image, Item) -> Item#{image_url => Image}.

%% @doc The og:image URL declared in a page, or `<<>>'.
%%
%% Pure, so every shape a publisher can write is testable without a network.
%% Deliberately tolerant of attribute order and quoting, because this is
%% hand-written HTML from forty-seven different newsrooms: `property' and
%% `content' appear in either order, in single or double quotes, and
%% `og:image:secure_url' and Twitter's `name="twitter:image"' are the same
%% offer under other names.
-spec of_html(binary() | {error, term()}) -> binary().
of_html(Html) when is_binary(Html) ->
    first_of([<<"og:image:secure_url">>, <<"og:image">>, <<"twitter:image">>], Html);
of_html(_Unfetched) ->
    <<>>.

first_of([], _Html) ->
    <<>>;
first_of([Property | Rest], Html) ->
    or_next(meta_content(Property, Html), Rest, Html).

or_next(<<>>, Rest, Html)  -> first_of(Rest, Html);
or_next(Content, _R, _H)   -> Content.

%% Both orders: <meta property=X content=Y> and <meta content=Y property=X>.
meta_content(Property, Html) ->
    either(capture(after_property(Property), Html), capture(before_property(Property), Html)).

either(<<>>, Fallback) -> Fallback;
either(Found, _F)      -> Found.

after_property(P) ->
    <<"<meta[^>]*(?:property|name)\\s*=\\s*[\"']", (esc(P))/binary,
      "[\"'][^>]*content\\s*=\\s*[\"']([^\"']+)[\"']">>.

before_property(P) ->
    <<"<meta[^>]*content\\s*=\\s*[\"']([^\"']+)[\"'][^>]*(?:property|name)\\s*=\\s*[\"']",
      (esc(P))/binary, "[\"']">>.

esc(P) -> binary:replace(P, <<":">>, <<"\\:">>, [global]).

capture(Pattern, Html) ->
    matched(re:run(Html, Pattern, [{capture, all_but_first, binary}, caseless, unicode])).

matched({match, [Content | _]}) -> unescape(string:trim(Content));
matched(nomatch)                -> <<>>.

%% Only the entities that actually appear in a URL inside an HTML attribute.
unescape(Url) ->
    lists:foldl(fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end, Url,
                [{<<"&amp;">>, <<"&">>}, {<<"&#38;">>, <<"&">>}, {<<"&quot;">>, <<"\"">>}]).

%% @doc Resolve a page-relative og:image against the article's own URL.
%%
%% A surprising number of newsrooms declare `content="/img/x.jpg"'. A
%% relative URL in an `<img src>' on somebody else's site is a broken image,
%% so it is resolved here or dropped.
-spec absolute(binary(), binary()) -> binary().
absolute(<<"http://", _/binary>> = Url, _Page)  -> Url;
absolute(<<"https://", _/binary>> = Url, _Page) -> Url;
absolute(<<"//", Rest/binary>>, Page)           -> <<(scheme(Page))/binary, "//", Rest/binary>>;
absolute(<<"/", _/binary>> = Path, Page)        -> join(origin(Page), Path);
absolute(_RelativeOrJunk, _Page)                -> <<>>.

scheme(<<"http://", _/binary>>)  -> <<"http:">>;
scheme(_Https)                   -> <<"https:">>.

origin(Page) ->
    case uri_string:parse(Page) of
        #{scheme := S, host := H} -> <<S/binary, "://", H/binary>>;
        _NotAUsableUrl            -> <<>>
    end.

join(<<>>, _Path)     -> <<>>;
join(Origin, Path)    -> <<Origin/binary, Path/binary>>.

%% --- fetching ---

fetch(Url) ->
    Request = {binary_to_list(Url),
               [{"User-Agent", ?UA}, {"Range", "bytes=0-" ++ integer_to_list(?HEAD_BYTES)}]},
    Opts = [{timeout, ?TIMEOUT_MS}, {connect_timeout, ?CONNECT_TIMEOUT_MS},
            {ssl, ssl_opts()}, {autoredirect, true}],
    head_of(catch httpc:request(get, Request, Opts, [{body_format, binary}])).

%% 206 is the Range being honoured; 200 is a publisher that ignored it and
%% sent the whole page, which is why the body is clipped either way.
head_of({ok, {{_V, Code, _R}, _H, Body}}) when Code =:= 200; Code =:= 206 ->
    clip(Body);
head_of(_AnythingElse) ->
    {error, no_page}.

clip(Body) when byte_size(Body) =< ?HEAD_BYTES -> Body;
clip(Body) -> binary:part(Body, 0, ?HEAD_BYTES).

%% The same posture as the feed fetch: verify against the system trust store,
%% no Big-Tech SDK. A publisher with a bad chain simply yields no picture.
ssl_opts() ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

mget(K, M) -> maps:get(K, M, <<>>).
