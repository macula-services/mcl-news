"""Generate mcl-news' two C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: what the service talks to
  c4-components.svg  Level 2: what it is made of

Drawn from the code, never from a template: the callbacks in
apps/mcl_news/src/mcl_news_service.erl, the one-child supervisor, the poll loop and
the dedupe window in sense_news_feeds.erl, the parse, enrich and og:image steps, the
fact in mcl_news_facts.erl, the deps in rebar.config, the org and realm settings in
config/sys.config.src, the health port in the Containerfile, and the variables
deploy/docker-compose.yml passes. When one of those changes, the diagram changes in
the same commit.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS custom
properties (rsvg-convert renders those black), so the SVGs render the same on
GitHub, in IDE previews and through rsvg-convert. After a change, render each
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it; keep
architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        # A box that is too small for its own words renders as text on top of the
        # next box, which no test would catch and a reader would read as the
        # diagram saying something it does not. Fail here instead.
        need = 70 + 16 * max(len(desc) - 1, 0) + 18
        if h < need:
            raise ValueError(f"{self.name}: {name} needs height {need}, has {h}")
        for line in desc:
            if 16 + 6.2 * len(line) > w - 16:
                raise ValueError(f"{self.name}: {name}: '{line}' is wider than {w - 32}px")
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "mcl-news system context", 1000, 690)
    d.box("b-per", 40, 30, 270, 120, "Operator", "[Person]",
          ["Runs it and sets MCL_NEWS_FEEDS,", "or leaves the built-in", "broadcaster list in place"],
          person=True)
    d.box("b-ext", 365, 30, 270, 120, "Consumer", "[External system]",
          ["A mind or an agent subscribed", "to news_item_reported_v1; the", "payload names no sender"])
    d.box("b-ext", 690, 30, 270, 120, "News sources", "[External system]",
          ["France 24, VRT NWS and DW by", "default: RSS/Atom over HTTPS,", "and the page for og:image"])
    d.box("b-sys", 365, 186, 270, 170, "mcl-news", "[mcl_om mesh service]",
          ["Polls every source every five", "minutes and reports each item it", "has not reported before as one fact,",
           "news_item_reported_v1. /health is a", "port, 8498. No procedure of its own,", "and no store"])
    d.box("b-mac", 365, 430, 270, 120, "macula-realm", "[Macula infrastructure]",
          ["The trust anchor and the grant:", "the org mcl-news, scope for 30", "days, and the boot claim"])
    d.box("b-mac", 690, 430, 270, 120, "Macula stations, mesh DHT", "[Macula infrastructure]",
          ["The pinned dial; the fact goes out", "through a station, and the DHT", "holds each advertisement"])
    d.edge("M175 150V168H400V186")
    d.text("t-rel", 183, 184, "deploys it, sets"); d.text("t-rel", 183, 200, "the feed list")
    d.edge("M560 186V150"); d.text("t-rel", 552, 172, "one fact per new item", anchor="end")
    d.edge("M600 186V168H825V150"); d.text("t-rel", 640, 164, "fetches every 5 minutes")
    d.edge("M460 356V430"); d.text("t-rel", 468, 384, "trust anchor, grant")
    d.edge("M620 356V370H825V430"); d.text("t-rel", 632, 364, "publishes the fact")
    d.text("t-desc", 40, 596, "The sensor asks the realm for no extra authority: its whole output is one fact, published under its own verified identity.")
    d.text("t-desc", 40, 614, "A source's first fetch seeds rather than floods: only its newest item is reported, and the")
    d.text("t-desc", 40, 632, "rest of the backlog is marked seen. A source being down, or a dark mesh, is deliberately not a health failure.")
    d.legend(650, boundary=False)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-news components", 1040, 1170)
    d.bound(40, 40, 968, 830, "mcl-news [Container]")
    d.box("b-cmp", 56, 70, 456, 120, "mcl_news_app", "[OTP application]",
          ["start/2 calls mcl_om:boot(mcl_news_service).", "The service exports no store_id/0 or data_dir/0,",
           "so mcl_om starts no reckon-db and no subscription."], code=True)
    d.box("b-sys", 536, 70, 456, 152, "mcl_news_service", "[:mcl_om_service behaviour]",
          ["The six callbacks. start/1 refuses a realm whose", "tag is not the sha256 of MCL_REALM_NAME, and its",
           "scope is mcl-news for 30 days. No procedure of its own;",
           "mcl-om adds mcl-news/info and mcl-news/get_limits,",
           "both open. capabilities/0 is the list."], code=True)
    d.box("b-cmp", 56, 230, 456, 120, "mcl_news_sup", "[supervisor, one_for_one]",
          ["One child, sense_news_feeds, which owns the poll", "loop, the dedupe window and the publishing.",
           "A crashed sensor is restarted and re-seeds."], code=True)
    d.box("b-cmp", 536, 230, 456, 120, "mcl_news_facts", "[Erlang module]",
          ["The one topic and its payload, every string", "tagged text, and report/1, which publishes",
           "synchronously and answers ok only once it did."], code=True)
    d.box("b-cmp", 56, 390, 456, 120, "sense_news_feeds", "[gen_server, the poll loop]",
          ["Every MCL_NEWS_POLL_MS: fetch each source, drop", "what it has seen, report the rest. Holds the",
           "bounded dedupe window and the primed set."], code=True)
    d.box("b-cmp", 536, 390, 456, 120, "parse_feed", "[Erlang module, pure]",
          ["One xpath sweep for RSS 2.0, RSS 1.0/RDF and", "Atom; the item id is a sha256 of the source's",
           "own guid, so the same story dedupes."], code=True)
    d.box("b-cmp", 56, 550, 456, 120, "enrich_item", "[Erlang module, pure]",
          ["Topic class and emoji, reporting and subject", "country, source type; a fixed taxonomy and a",
           "gazetteer sweep, with a safe default for each."], code=True)
    d.box("b-cmp", 536, 550, 456, 120, "og_image", "[Erlang module, one network step]",
          ["For an item with no picture, reads the", "publisher's own og:image from the article page,",
           "bounded and silent on failure. Never for old items."], code=True)
    d.box("b-mac", 56, 710, 456, 120, "mcl_om", "[library, ~> 1.6]",
          ["boot/1: loads the identity key, joins the", "realm, dials the pinned stations, serves /health",
           "on 8498, and carries mcl_om_pubsub:publish/3."], code=True)
    d.box("b-mac", 536, 710, 456, 120, "macula SDK", "[library, ~> 18.0, wire 1.0]",
          ["QUIC transport, pubsub over the stations, and", "the publisher every link verified, which is",
           "what a fact's attribution rests on."], code=True)
    d.edge("M56 130H16V770H56"); d.text("t-rel", 30, 450, "calls mcl_om:boot/1", anchor="middle", rotate=-90)
    d.edge("M512 130H536"); d.text("t-rel", 524, 122, "boots", anchor="middle")
    d.edge("M536 160H520V210H284V230"); d.text("t-rel", 300, 206, "starts")
    d.edge("M200 350V390"); d.text("t-rel", 208, 374, "one child")
    d.edge("M512 450H536"); d.text("t-rel", 524, 442, "parses", anchor="middle")
    d.edge("M200 510V550"); d.text("t-rel", 208, 534, "enriches each item")
    d.edge("M350 510V530H700V550"); d.text("t-rel", 420, 526, "fills og:image")
    d.edge("M450 390V378H700V350"); d.text("t-rel", 500, 374, "reports each item")
    d.edge("M512 770H536"); d.text("t-rel", 524, 762, "dials", anchor="middle")
    d.box("b-ext", 64, 900, 920, 136, "Host environment", "[read at boot; some defaults are baked in]",
          ["MCL_REALM and MCL_REALM_NAME are required and must agree; MCL_REALM_KEY is the trust anchor; MACULA_STATION_SEEDS with",
           "MACULA_STATION_NODE_IDS is the pinned dial. MCL_NEWS_FEEDS replaces the built-in broadcaster list with your own sources.",
           "MCL_NEWS_POLL_MS, MCL_NEWS_SEED_COUNT and MCL_NEWS_MAX_SEEN tune the poll, the seed and the dedupe window.",
           "MCL_SERVICE_NAME and MCL_BOX label the boot claim; MCL_HEALTH_PORT is 8498."],
          code=True)
    d.text("t-desc", 64, 1070, "No store: the only memory is a bounded set of item ids already reported, rebuilt on restart. An item is marked seen only once its")
    d.text("t-desc", 64, 1088, "publish succeeded, so a dark mesh delays a report and loses none. A source's first fetch seeds rather than floods: only its newest")
    d.text("t-desc", 64, 1106, "item is reported, and the rest of its backlog is marked seen, at boot or when a source comes back after being down.")
    d.legend(1130)
    d.write()


if __name__ == "__main__":
    for make in (context, components):
        make()
