// Custom UI router — see specs/war-infra-spec.md §6.1
//
// Bound to /ui/* on the zone. Serves every custom UI from one shared bucket
// keyed by slug prefix, and rewrites storage 404s to that slug's index.html
// with HTTP 200.
//
// The second part is why this Worker exists at all. Object storage cannot
// return one object's bytes under another's status code — where it offers an
// error document, the response keeps its 404 — and SPA deep links need a 200.
//
// Adding a custom UI requires no change here: the slug is a key prefix, not
// configuration.

const SLUG_PATTERN = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/

export default {
  async fetch(request, env) {
    const url = new URL(request.url)

    // /ui/{slug}/{...rest}
    const segments = url.pathname.split('/').filter(Boolean)
    if (segments[0] !== 'ui' || segments.length < 2) {
      return new Response('Not found', { status: 404 })
    }

    const slug = segments[1]

    // /ui/default/* is served by App Platform, not from storage. The route
    // pattern cannot express the exclusion, so it is enforced here.
    if (slug === 'default') {
      return fetch(request)
    }

    // The slug reaches storage as a key prefix. Validate it for the same reason
    // the deploy pipeline does: a traversal sequence would read across into
    // another brand's bundle in the shared bucket.
    if (!SLUG_PATTERN.test(slug)) {
      return new Response('Not found', { status: 404 })
    }

    const base = `${env.STORAGE_CDN_ORIGIN}/${slug}`
    const rest = segments.slice(2).join('/')

    // A bare /ui/{slug}/ means the shell.
    if (rest === '') {
      return shell(base)
    }

    const direct = await fetch(`${base}/${rest}`, {
      method: 'GET',
      headers: request.headers,
    })

    if (direct.status !== 404) {
      return direct
    }

    // Unmatched path inside a registered UI: hand back the shell so the
    // client-side router can take the route.
    return shell(base)
  },
}

async function shell(base) {
  const response = await fetch(`${base}/index.html`)

  if (!response.ok) {
    // The slug has no bundle uploaded. A registered slug always should, so this
    // is a genuine 404 rather than something to paper over.
    return new Response('Not found', { status: 404 })
  }

  const headers = new Headers(response.headers)
  headers.set('content-type', 'text/html; charset=utf-8')
  // index.html is never cached, or deploys would not be picked up (spec §7).
  headers.set('cache-control', 'no-store')

  return new Response(response.body, { status: 200, headers })
}
