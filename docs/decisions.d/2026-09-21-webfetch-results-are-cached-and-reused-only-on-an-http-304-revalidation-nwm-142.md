---
seq: 22
date: 2026-09-21
level: 3
slug: 2026-09-21-webfetch-results-are-cached-and-reused-only-on-an-http-304-revalidation-nwm-142
title: "WebFetch results are cached and reused only on an HTTP 304 revalidation (NWM-142)"
---

The mechanism, adopted from `addyosmani/agent-skills` (`hooks/sdd-cache-pre.sh`
and `sdd-cache-post.sh`, audited 2026-09-20): a PreToolUse hook matching
WebFetch looks the URL up in a local cache. If an entry exists, it issues a
conditional HEAD carrying `If-None-Match` and `If-Modified-Since`. On a 304 it
blocks the fetch (exit 2) and hands the model the cached reading through
stderr; on anything else it allows the real fetch. A PostToolUse hook stores
the reading together with the validators the origin is advertising.

Shipped here as `hooks/webfetch-cache-pre.sh` and `hooks/webfetch-cache-post.sh`
because the ownership table gives the cheap-reader hooks to night-watchman, and
the whole point is not paying twice for a body the model has already read.

There is deliberately no TTL and the prompt is not part of the cache key.
Freshness is delegated entirely to the origin, so a reuse is a fresh
verification rather than a memory read — which is what keeps this compatible
with the standing rule that anything carrying a version or a release cadence is
looked up, not recalled. A hit asserts only what the origin just asserted: the
bytes have not changed since the reading was taken.

The cached body is not raw HTML. It is one agent's model-processed reading of
the page under its own prompt, so the originating prompt is stored alongside and
printed on every hit; the next agent has to judge whether that reading answers
its question. There is no "ask twice and it passes through" escape hatch of the
kind `read-shunt.sh` has, because a second WebFetch of the same URL in one
session is exactly the case this hook exists to serve. The escape hatch is a
plain `curl` in Bash, which the hook never matches.

Three consequences of delegating freshness that the implementation had to
absorb. An origin advertising no ETag and no Last-Modified is never cached at
all, since without a TTL there would be nothing to revalidate against. Claude
Code does not hand a hook the tool's response headers, so the post hook issues
its own HEAD to observe them, and skips the write unless that HEAD is a clean
200. And a credentialed URL — userinfo before the host, or a
token/secret/signature-shaped query parameter — is never stored or served,
checked before the URL is hashed so it leaves no trace in the cache directory.

Having no TTL creates one failure mode that is not a refetch, and the post
hook is where it has to be stopped. Not every successful WebFetch carries page
content: a cross-host redirect comes back as a short notice asking the model to
fetch the target instead, and a robots.txt or 403 refusal comes back as error
prose, both reported as success. Cached, either one would be served forever,
because the pre hook would keep revalidating against a validator that keeps
matching and keep printing the notice under a banner asserting the content is
current. Three gates refuse it: the tool's own `.tool_response.code` must be
200 when the payload carries one, the validator HEAD does not follow redirects
so a redirecting URL answers 3xx and fails the 200 gate rather than being keyed
under the target's validators, and a reading under `NW_WEBFETCH_MIN_BYTES`
(200) is refused because the notice shapes are short and a page reading is not.

Both hooks fail open on every ambiguity: no cache directory, an unwritable one,
a missing `jq` or `curl`, a HEAD that errors or times out, a malformed entry, an
empty body. A needless refetch costs tokens; serving a stale body would be a
correctness bug. The credentialed-URL match is over-broad on purpose — the
substrings are looked for anywhere in the query string, so `author=` and
`session_type=` also opt a URL out — because a false positive costs one refetch
and a false negative puts a credential on disk.
