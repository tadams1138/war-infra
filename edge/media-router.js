// Media router — see specs/war-infra-spec.md §6, §7, §15.5
//
// Bound to /media/* on the zone. Fetches contestant image variants directly
// from the Spaces CDN, stripping the /media prefix so bucket keys stay clean.
//
// Exists instead of a Cloudflare Origin Rule because redirecting to a
// different origin's hostname needs that rule type's Host Header override,
// which requires a paid Cloudflare plan. Fetching the CDN's own hostname
// directly needs no such override — the correct Host header is implicit in
// the URL being fetched.
//
// cacheEverything + a fixed cacheTtl (rather than relying on Cache Rules to
// respect whatever Cache-Control the origin sends) is deliberate, not just a
// side effect of using a Worker: variant keys are content-addressed (spec
// §11) — width and content are baked into the filename — so a cache entry
// can only ever be stale in the sense of "not yet warmed", never "serving
// the wrong bytes for this key". A year is safe regardless of what the
// origin sends, which matters because the origin does not currently send a
// long-lived Cache-Control at all (see the note in the spec at §15.5).

export default {
  async fetch(request, env) {
    const url = new URL(request.url)

    // /media/{...rest}
    if (!url.pathname.startsWith('/media/')) {
      return new Response('Not found', { status: 404 })
    }

    // /media/originals/* never reaches here — the WAF custom rule (spec
    // §15.5) blocks it ahead of this Worker in the request lifecycle.
    const rest = url.pathname.slice('/media/'.length)
    const origin = `${env.MEDIA_CDN_ORIGIN}/${rest}${url.search}`

    return fetch(origin, {
      method: 'GET',
      headers: request.headers,
      cf: {
        cacheEverything: true,
        cacheTtl: 31536000,
      },
    })
  },
}
