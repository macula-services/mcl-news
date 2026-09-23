%%% @doc Parse an RSS/Atom document into a list of news items. Pure, so it is
%%% unit-tested without a live network or mesh.
%%%
%%% One xpath sweep covers the three shapes we meet in the wild: RSS 2.0 and RSS
%%% 1.0/RDF (`//item') and Atom (`//entry'). For each we extract a title, a
%%% summary, a link, a stable id, and a best-effort publication time. The id is a
%%% SHA-256 of the source's own guid/id (or the url+title when it gives none), so
%%% the sensor dedupes the same story across polls without trusting the source to
%%% hand us a unique key.
-module(parse_feed).
-include_lib("xmerl/include/xmerl.hrl").

%% Widest image a card should hotlink. Above this the source is offering its
%% master copy, not an illustration.
-define(MAX_IMAGE_WIDTH, 1600).

-export([parse/1]).

%% @doc Parse a feed document (raw bytes) into `[Item]'. Each Item is a map with
%% item_id, title, summary, url, published_at (ms, 0 when unparseable), topics,
%% image_url (`<<>>' when the feed offers none).
%% Returns [] on any parse error — a malformed feed yields no items, never a
%% crash.
-spec parse(binary() | string()) -> [map()].
parse(Xml) when is_binary(Xml) ->
    parse(binary_to_list(Xml));
parse(Xml) when is_list(Xml) ->
    scan(safe_scan(Xml)).

%% --- Internal ---

%% Keep the raw bytes and let xmerl honour the document's own <?xml encoding?>
%% declaration (EU feeds are UTF-8, some are latin-1). Decoding here first would
%% double-decode.
%%
%% ENTITY DECLARATIONS ARE REFUSED. xmerl on OTP 28 rejects a document that
%% declares entities (`entities_not_allowed', measured on 28.4.3), so a hostile
%% feed declaring `<!ENTITY k SYSTEM "file:///...">' yields no items rather
%% than a local file published as a title. Never pass `allow_entities' here;
%% parse_feed_tests pins this.
safe_scan(Xml) ->
    try xmerl_scan:string(Xml, [{quiet, true}])
    catch _:_ -> error
    end.

scan({Doc, _Rest}) ->
    [item(N) || N <- feed_nodes(Doc)];
scan(_Bad) ->
    [].

feed_nodes(Doc) ->
    xmerl_xpath:string("//item", Doc) ++ xmerl_xpath:string("//entry", Doc).

item(Node) ->
    Title   = text(Node, "title"),
    Summary = first([text(Node, "description"),
                     text(Node, "summary"),
                     text(Node, "content")]),
    Url     = link_of(Node),
    Ident   = first([text(Node, "guid"), text(Node, "id"), Url, Title]),
    Date    = first([text(Node, "pubDate"), text(Node, "published"),
                     text(Node, "updated"), text(Node, "date"),
                     %% RSS 1.0/RDF dates the story with a namespaced <dc:date>;
                     %% match on local name so the prefix does not matter.
                     text_local(Node, "date")]),
    #{item_id      => stable_id(Ident),
      title        => Title,
      summary      => strip_tags(Summary),
      url          => Url,
      image_url    => image_of(Node),
      published_at => parse_date(Date),
      topics       => categories(Node)}.

%% @doc The article's own illustration, as a LINK. Nothing is copied: a feed's
%% `media:content' / `media:thumbnail' / `enclosure' URL is published by the
%% source precisely so a reader can display it, and linking leaves the source in
%% control of it -- they can change it, pull it, or refuse it.
%%
%% Three shapes, all seen in the live EU feeds this sensor polls (surveyed
%% 2026-09-02, 16 of 31 sources carry one):
%%
%%   guardian  <media:content width="140|460|700" url="....jpg?width=140">
%%   err       <media:thumbnail url='....jpg' height='75' width='75'/>
%%   nos       <enclosure type="image/webp" url="....webp"/>
%%
%% Namespaced elements are matched by LOCAL NAME, the way `text_local/2' already
%% matches `dc:date', so a prefix nobody declared cannot hide the image. That
%% local-name match would also catch Atom's own `<content>' (the article body),
%% which is why a candidate must carry a `url' attribute -- Atom's does not.
image_of(Node) ->
    best_image(media_candidates(Node, "content") ++
               media_candidates(Node, "thumbnail") ++
               enclosure_candidates(Node)).

media_candidates(Node, Local) ->
    Els = xmerl_xpath:string("*[local-name()='" ++ Local ++ "']", Node),
    lists:filtermap(fun(E) -> candidate(E) end, Els).

enclosure_candidates(Node) ->
    lists:filtermap(fun(E) -> candidate(E) end,
                    xmerl_xpath:string("enclosure", Node)).

candidate(El) ->
    weigh(elem_attr(El, "url"), elem_attr(El, "type"), El).

weigh(<<>>, _Type, _El) ->
    false;
weigh(Url, Type, El) ->
    kept(is_image(Type, Url), Url, El).

kept(true, Url, El) -> {true, {elem_width(El), Url}};
kept(false, _Url, _El) -> false.

%% An explicit image type settles it. Without one -- guardian and err give no
%% type at all -- the extension does, checked after the query string is cut off,
%% since a sized URL ends `.jpg?width=700'. Anything else is refused rather than
%% guessed at: an `enclosure' is equally the element podcasts put audio in.
is_image(<<"image/", _/binary>>, _Url) -> true;
is_image(<<>>, Url)                    -> has_image_extension(Url);
is_image(_OtherType, _Url)             -> false.

has_image_extension(Url) ->
    [Path | _Query] = binary:split(Url, [<<"?">>, <<"#">>]),
    lists:any(fun(Ext) -> is_suffix(Ext, string:lowercase(Path)) end,
              [<<".jpg">>, <<".jpeg">>, <<".png">>, <<".webp">>, <<".gif">>, <<".avif">>]).

is_suffix(Suffix, Bin) when byte_size(Bin) >= byte_size(Suffix) ->
    binary:part(Bin, byte_size(Bin) - byte_size(Suffix), byte_size(Suffix)) =:= Suffix;
is_suffix(_Suffix, _Bin) ->
    false.

%% The widest the source offers, capped: a feed that lists 140, 460 and 700 is
%% offering a thumbnail and a card image, and the card is the one worth linking.
%% Above ?MAX_IMAGE_WIDTH we take the SMALLEST instead, because a page should
%% not hotlink somebody's four-thousand-pixel master to draw a 700px card.
best_image([]) ->
    <<>>;
best_image(Candidates) ->
    pick(lists:sort([C || {W, _U} = C <- Candidates, W =< ?MAX_IMAGE_WIDTH]),
         lists:sort(Candidates)).

pick([], AllSorted)    -> url_of(hd(AllSorted));
pick(WithinCap, _All)  -> url_of(lists:last(WithinCap)).

url_of({_Width, Url}) -> Url.

%% Width is advisory: err gives 75, guardian gives three, nos gives none. A
%% missing width sorts first, so it is only ever chosen when nothing better
%% exists.
elem_width(El) ->
    to_width(elem_attr(El, "width")).

to_width(<<>>) ->
    0;
to_width(Bin) ->
    parsed_width(string:to_integer(Bin)).

parsed_width({W, _Rest}) when is_integer(W), W > 0 -> W;
parsed_width(_NotANumber)                          -> 0.

elem_attr(#xmlElement{attributes = Attrs}, Name) ->
    collect_attr([A || #xmlAttribute{name = N} = A <- Attrs, atom_to_list(N) =:= Name]).

%% RSS carries the link as element text; Atom carries it as a `href' attribute.
%% Prefer the text; fall back to the attribute.
link_of(Node) ->
    first([text(Node, "link"), attr(Node, "link", "href")]).

categories(Node) ->
    [B || B <- [text_of(T) || T <- xmerl_xpath:string("category", Node)],
          B =/= <<>>].

%% Text content of a child element, trimmed. Concatenates text + CDATA runs.
text(Node, Tag) ->
    collect_text(xmerl_xpath:string(Tag ++ "/text()", Node)).

text_of(Node) ->
    collect_text(xmerl_xpath:string("text()", Node)).

%% Text of a child element matched by local name, ignoring its namespace prefix
%% (e.g. `dc:date' -> "date"). RSS 1.0/RDF feeds carry the date this way.
text_local(Node, Local) ->
    collect_text(xmerl_xpath:string("*[local-name()='" ++ Local ++ "']/text()", Node)).

collect_text(Nodes) ->
    trim(unicode:characters_to_binary([V || #xmlText{value = V} <- Nodes])).

attr(Node, Tag, Attr) ->
    collect_attr(xmerl_xpath:string(Tag ++ "/@" ++ Attr, Node)).

collect_attr([#xmlAttribute{value = V} | _]) ->
    trim(unicode:characters_to_binary(V));
collect_attr(_None) ->
    <<>>.

trim(Bin) when is_binary(Bin) ->
    string:trim(Bin);
trim(_NotBin) ->
    <<>>.

first([<<>> | Rest]) -> first(Rest);
first([Bin | _]) when is_binary(Bin), Bin =/= <<>> -> Bin;
first([_ | Rest]) -> first(Rest);
first([]) -> <<>>.

%% A stable, uniform id: hash whatever the source gave us as identity. The same
%% story on the next poll hashes the same, so the dedupe window catches it.
stable_id(<<>>) ->
    <<>>;
stable_id(Ident) when is_binary(Ident) ->
    Hex = binary:encode_hex(crypto:hash(sha256, Ident)),
    string:lowercase(binary:part(Hex, 0, 32)).

%% Descriptions often carry HTML. Strip tags to a plain summary — consumers read
%% prose, and the realm's wire renders plain text.
strip_tags(<<>>) ->
    <<>>;
strip_tags(Bin) when is_binary(Bin) ->
    trim(re:replace(Bin, <<"<[^>]*>">>, <<" ">>, [global, {return, binary}])).

%% Best-effort publication time in ms. RSS uses RFC822 ("Mon, 02 Jan 2026
%% 15:04:05 +0000"), Atom uses RFC3339 ("2026-01-02T15:04:05Z"). We ignore the
%% timezone (treat as UTC) — freshness, not forensics. Unparseable -> 0, and the
%% sensor's own fetched_at carries authoritative freshness.
parse_date(<<>>) ->
    0;
parse_date(Bin) when is_binary(Bin) ->
    epoch_ms(match_date(Bin)).

match_date(Bin) ->
    rfc3339(re:run(Bin, <<"(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})">>,
                   [{capture, all_but_first, binary}]), Bin).

rfc3339({match, [Y, Mo, D, H, Mi, S]}, _Bin) ->
    {{int(Y), int(Mo), int(D)}, {int(H), int(Mi), int(S)}};
rfc3339(nomatch, Bin) ->
    rfc822(re:run(Bin, <<"(\\d{1,2}) (\\w{3}) (\\d{4}) (\\d{2}):(\\d{2}):(\\d{2})">>,
                  [{capture, all_but_first, binary}])).

rfc822({match, [D, Mon, Y, H, Mi, S]}) ->
    {{int(Y), month(Mon), int(D)}, {int(H), int(Mi), int(S)}};
rfc822(nomatch) ->
    error.

epoch_ms(error) ->
    0;
epoch_ms({{_, 0, _}, _}) ->
    0;
epoch_ms(DateTime) ->
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    (calendar:datetime_to_gregorian_seconds(DateTime) - Epoch) * 1000.

int(Bin) ->
    binary_to_integer(Bin).

month(<<"Jan">>) -> 1;  month(<<"Feb">>) -> 2;  month(<<"Mar">>) -> 3;
month(<<"Apr">>) -> 4;  month(<<"May">>) -> 5;  month(<<"Jun">>) -> 6;
month(<<"Jul">>) -> 7;  month(<<"Aug">>) -> 8;  month(<<"Sep">>) -> 9;
month(<<"Oct">>) -> 10; month(<<"Nov">>) -> 11; month(<<"Dec">>) -> 12;
month(_Unknown)  -> 0.
