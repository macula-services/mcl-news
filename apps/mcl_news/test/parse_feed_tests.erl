%%% @doc Unit tests for parse_feed — pure, no network, no mesh.
-module(parse_feed_tests).
-include_lib("eunit/include/eunit.hrl").

rss2_test() ->
    Xml = <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            "<rss version=\"2.0\"><channel><title>Chan</title>"
            "<item>"
            "<title>Energy deal signed</title>"
            "<description>A summary here.</description>"
            "<link>https://example.eu/a</link>"
            "<guid>urn:a-1</guid>"
            "<pubDate>Mon, 02 Jan 2026 15:04:05 +0000</pubDate>"
            "<category>energy</category>"
            "</item>"
            "</channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<"Energy deal signed">>, maps:get(title, Item)),
    ?assertEqual(<<"A summary here.">>, maps:get(summary, Item)),
    ?assertEqual(<<"https://example.eu/a">>, maps:get(url, Item)),
    ?assertEqual([<<"energy">>], maps:get(topics, Item)),
    ?assert(maps:get(published_at, Item) > 0),
    ?assertEqual(32, byte_size(maps:get(item_id, Item))).

atom_test() ->
    Xml = <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
            "<entry>"
            "<title>Vote passes</title>"
            "<summary>The parliament voted.</summary>"
            "<link href=\"https://example.eu/b\" rel=\"alternate\"/>"
            "<id>tag:example.eu,2026:b</id>"
            "<updated>2026-01-02T15:04:05Z</updated>"
            "</entry>"
            "</feed>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<"Vote passes">>, maps:get(title, Item)),
    ?assertEqual(<<"The parliament voted.">>, maps:get(summary, Item)),
    ?assertEqual(<<"https://example.eu/b">>, maps:get(url, Item)),
    ?assert(maps:get(published_at, Item) > 0).

%% RSS 1.0 / RDF keeps <item> at the top level, not under <channel>. The //item
%% sweep still finds it.
rdf_test() ->
    Xml = <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" "
            "xmlns=\"http://purl.org/rss/1.0/\">"
            "<channel><title>C</title></channel>"
            "<item><title>Grid news</title>"
            "<description>Load balanced.</description>"
            "<dc:date xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
            "2026-07-17T14:30:00Z</dc:date>"
            "<link>https://example.de/c</link></item>"
            "</rdf:RDF>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<"Grid news">>, maps:get(title, Item)),
    ?assertEqual(<<"https://example.de/c">>, maps:get(url, Item)),
    %% The namespaced <dc:date> is matched by local name.
    ?assert(maps:get(published_at, Item) > 0).

%% The same story parses to the same id across polls (dedupe depends on it).
stable_id_test() ->
    Xml = <<"<rss><channel><item><title>T</title><guid>same</guid>"
            "<link>https://x/1</link></item></channel></rss>">>,
    [#{item_id := Id1}] = parse_feed:parse(Xml),
    [#{item_id := Id2}] = parse_feed:parse(Xml),
    ?assertEqual(Id1, Id2),
    ?assertNotEqual(<<>>, Id1).

%% Two items with different guids get different ids.
distinct_id_test() ->
    Xml = <<"<rss><channel>"
            "<item><title>A</title><guid>g-a</guid><link>https://x/a</link></item>"
            "<item><title>B</title><guid>g-b</guid><link>https://x/b</link></item>"
            "</channel></rss>">>,
    [#{item_id := A}, #{item_id := B}] = parse_feed:parse(Xml),
    ?assertNotEqual(A, B).

html_summary_is_stripped_test() ->
    Xml = <<"<rss><channel><item><title>T</title>"
            "<description>&lt;p&gt;Hello &lt;b&gt;world&lt;/b&gt;&lt;/p&gt;</description>"
            "<guid>h</guid><link>https://x/h</link></item></channel></rss>">>,
    [#{summary := S}] = parse_feed:parse(Xml),
    ?assertEqual(nomatch, binary:match(S, <<"<">>)),
    ?assertNotEqual(nomatch, binary:match(S, <<"Hello">>)).

garbage_yields_no_items_test() ->
    ?assertEqual([], parse_feed:parse(<<"not xml at all">>)),
    ?assertEqual([], parse_feed:parse(<<>>)).

no_date_is_zero_test() ->
    Xml = <<"<rss><channel><item><title>T</title><guid>n</guid>"
            "<link>https://x/n</link></item></channel></rss>">>,
    [#{published_at := P}] = parse_feed:parse(Xml),
    ?assertEqual(0, P).


%%% ── Illustrations ────────────────────────────────────────────────
%%% Shapes taken from the live feeds, not invented: guardian offers three
%%% widths of one picture with no type at all, err single-quotes a
%%% media:thumbnail, nos types an enclosure image/webp.

guardian_media_content_picks_the_widest_test() ->
    Xml = <<"<?xml version=\"1.0\"?><rss xmlns:media=\"http://search.yahoo.com/mrss/\">"
            "<channel><item><title>T</title><link>https://g.example/a</link>"
            "<media:content width=\"140\" url=\"https://i.example/x.jpg?width=140\"/>"
            "<media:content width=\"460\" url=\"https://i.example/x.jpg?width=460\"/>"
            "<media:content width=\"700\" url=\"https://i.example/x.jpg?width=700\"/>"
            "</item></channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<"https://i.example/x.jpg?width=700">>, maps:get(image_url, Item)).

err_single_quoted_thumbnail_test() ->
    Xml = <<"<?xml version=\"1.0\"?><rss xmlns:media=\"http://search.yahoo.com/mrss/\">"
            "<channel><item><title>T</title><link>https://err.example/a</link>"
            "<media:thumbnail url='https://s.example/p.jpg' height='75' width='75' />"
            "</item></channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<"https://s.example/p.jpg">>, maps:get(image_url, Item)).

typed_enclosure_is_taken_test() ->
    Xml = <<"<?xml version=\"1.0\"?><rss><channel><item><title>T</title>"
            "<link>https://nos.example/a</link>"
            "<enclosure type=\"image/webp\" url=\"https://images.example/a-1024x576.webp\"/>"
            "</item></channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<"https://images.example/a-1024x576.webp">>, maps:get(image_url, Item)).

%% An enclosure is equally where a podcast puts its audio. Taking it would put a
%% broken image on the page and hotlink somebody's media file to do it.
audio_enclosure_is_refused_test() ->
    Xml = <<"<?xml version=\"1.0\"?><rss><channel><item><title>T</title>"
            "<link>https://pod.example/a</link>"
            "<enclosure type=\"audio/mpeg\" url=\"https://pod.example/ep1.mp3\"/>"
            "</item></channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<>>, maps:get(image_url, Item)).

%% Atom's own <content> matches the same local name as media:content. It is the
%% article body and carries no url attribute, so it must never be read as one.
atom_content_body_is_not_an_image_test() ->
    Xml = <<"<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\">"
            "<entry><title>T</title><link href=\"https://a.example/x\"/>"
            "<content type=\"html\">&lt;p&gt;the article body&lt;/p&gt;</content>"
            "</entry></feed>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<>>, maps:get(image_url, Item)).

a_feed_with_no_picture_says_so_test() ->
    Xml = <<"<?xml version=\"1.0\"?><rss><channel><item><title>T</title>"
            "<link>https://dw.example/a</link></item></channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<>>, maps:get(image_url, Item)).

%% A source offering only its master copy: too big to hotlink for a card, so the
%% smallest on offer is taken instead of the widest.
oversized_master_falls_back_to_the_smallest_test() ->
    Xml = <<"<?xml version=\"1.0\"?><rss xmlns:media=\"http://search.yahoo.com/mrss/\">"
            "<channel><item><title>T</title><link>https://m.example/a</link>"
            "<media:content width=\"4403\" url=\"https://i.example/master.jpg\"/>"
            "<media:content width=\"2200\" url=\"https://i.example/big.jpg\"/>"
            "</item></channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<"https://i.example/big.jpg">>, maps:get(image_url, Item)).

%% No type and no recognisable extension: refused rather than guessed at.
untyped_non_image_url_is_refused_test() ->
    Xml = <<"<?xml version=\"1.0\"?><rss><channel><item><title>T</title>"
            "<link>https://x.example/a</link>"
            "<enclosure url=\"https://x.example/report.pdf\"/>"
            "</item></channel></rss>">>,
    [Item] = parse_feed:parse(Xml),
    ?assertEqual(<<>>, maps:get(image_url, Item)).
