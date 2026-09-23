# mcl-news

**Sovereign news sensor: polls public RSS/Atom sources and reports each new item as a mesh fact**

Built on macula 12 and `mcl_om`.

## What it does

A sensor. Every five minutes it fetches each configured RSS/Atom source over
HTTPS (certificates checked against the system CA store, plain OTP `inets` and
`ssl`, no third-party news API), parses it, and reports every item it has not
reported before as one fact:

    <realm>/mcl-news/news/wire/news_item_reported_v1

The defaults are European public broadcasters: France 24, VRT NWS and DW.

Each fact carries the item (`item_id`, `source`, `title`, `summary`, `url`,
`image_url`, `lang`, `topics`, `published_at`), a deterministic enrichment
(`topic_class`, `emoji`, `reporting_country`, `reporting_country_name`,
`subject_country`, `subject_country_name`, `source_type`), `fetched_at`, and
`body`, a readable headline line for consumers that reason over text. Every
string is tagged text; times are milliseconds. `image_url` links the
publisher's own picture (from the feed, or `og:image` on the article page) and
is empty when there is none.

**One topic.** Category, country and source type are payload fields to filter
on. The service this one replaces also published every item to one sub-topic
per axis value, so each mind of a society could subscribe to a slice; no
consumer of that exists, and values belong in the payload, not in topic names.
It can come back when a consumer needs it.

**Who reported it** is the publisher macula verified on delivery, this
sensor's own node identity. The payload carries no sender label.

**The first poll seeds, it does not flood:** only the newest item per source is
reported, and the rest of the backlog is marked seen. Item ids already reported
are remembered in a bounded in-memory window (4000 by default), rebuilt on
restart.

It offers no procedure and asks the realm for no extra authority. `/health` is
green while the sensor runs; a source that is down, or a dark mesh, is not a
health failure.

## Running it

    rebar3 compile
    rebar3 eunit
    rebar3 lint
    rebar3 dialyzer

    scripts/health.sh                      # against a running node

Building the image needs a Rust toolchain, because macula ships a QUIC NIF and
the alpine build compiles it from source rather than fetching one linked against
a different libc.

    podman build -t mcl-news -f Containerfile .

## Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `MCL_REALM` | required | 64-hex realm tag, the `sha256` of the realm's name. No default: a service that guesses its realm announces itself where nobody can attribute it. |
| `MCL_REALM_KEY` | required | The realm's public signing key, hex encoded: the **trust anchor**, not an identifier. Every org-namespaced advertisement is verified against it, so without it nothing resolves, the boot claim never reaches the realm, and the service stays green while unreachable. Public material, not a secret. |
| `MACULA_STATION_SEEDS` | required | Station hosts to dial, `host[:port]`, comma-separated. No default: naming a realm costs nothing, dialling a production station from every dev clone does. |
| `MACULA_STATION_NODE_IDS` | required | The matching 64-hex station node ids, comma-separated, index-paired with the seeds. The dial is pinned (D5): mcl_om refuses to boot a pool with an unpinned seed. |
| `MCL_REALM_NAME` | required | The realm's name, as the fact topic carries it. At start, `sha256` of it must equal `MCL_REALM` or the node refuses to start. |
| `MCL_NEWS_FEEDS` | built-in list | Sources, `name|url|lang|country|type` joined by commas. `country` (ISO-2) and `type` (`broadcaster`, `wire`, `private`) are optional. Replaces the defaults wholesale. |
| `MCL_NEWS_POLL_MS` | `300000` | How often every source is polled. |
| `MCL_NEWS_SEED_COUNT` | `1` | Items per source reported on the first poll. |
| `MCL_NEWS_MAX_SEEN` | `4000` | Item ids remembered, so old news is not reported again. |
| `MCL_HEALTH_PORT` | `8498` | Health endpoint, assigned in macula-fleet `PORTS.md`. Host networking makes a collision a silent bind failure, so take a new one from there rather than picking one. |
| `MCL_NODE_NAME` | `mcl_news` | Erlang node name. |
| `MCL_NODE_HOST` | `127.0.0.1` | Erlang node host. |
| `MCL_COOKIE` | `mcl_news` | Erlang cookie. |

`deploy/docker-compose.yml` runs it, and carries what the service knows about
itself. If you deploy through something else, let that carry **placement**: which
host, which station, which realm, which secret store. Keeping the two apart is
what stops a config table in a README and the real environment drifting.

## Deployment

The image has two channels. A push to `main` publishes
`ghcr.io/macula-services/mcl-news:latest`, the deploy channel: a host that follows
`:latest` deploys every merge. A `v*` tag publishes its own version and nothing
else, the rollback archive: pin a host to one to roll back. A push that changes
only documentation builds no image (`scripts/is_image_push.sh`).

The service's org, the `<org>` in every procedure it offers (`<org>/<name>`), is
this repository's name, fixed in `config/sys.config.src`. The realm's grant names
it; without an org mcl_om advertises nothing.

Two things CI cannot do for you, both of which have bitten:

1. The registry package may be created **private**, and the pull then fails on
   the host with a bare `unauthorized` that names nothing. Check it after the
   first build. On ghcr the `org.opencontainers.image.source` label in the
   Containerfile is what links the package to the repository.
2. The host needs `MCL_REALM`, `MCL_REALM_NAME` and the pinned station pair
   supplied from somewhere they are not committed.

## The service contract

Six callbacks in `mcl_news_service`, all required, all resolved **by name** by
`mcl_om` at startup on a live node. The `-behaviour(mcl_om_service)`
attribute turns a missing one into a compile error rather than an `undef` where
nobody is watching, and the eunit suite guards the attribute itself.

### Adding a store later

This service has no `reckon-db` store, which is the right answer for most. The
reckon-db applications run either way; what a store adds is a data directory, an
open handle, and something written.

The cheapest way to get one is to scaffold again with `store=1`, which generates
the callbacks, the config and the guards together.

⚠ **By hand it is three things and not one, and the missing third crash-loops the
node.** Export `store_id/0` and `data_dir/0`; add the `evoq` adapter block to
`config/sys.config.src`, without which boot raises
`{not_configured, event_store_adapter}` before any service code runs; and mount a
volume in the compose file. A sibling service put two of three fleet nodes into a
boot loop by doing the first and not the second.

## Licence

Apache-2.0.
