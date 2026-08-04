// Scheduled task dispatch — see specs/war-infra-spec.md §12, §15.4
//
// App Platform has no cron primitive (its jobs are deploy-lifecycle only), so
// the scheduler role sits at the edge. This Worker has no fetch handler — it is
// invoked solely by its Cron Trigger and is not routed on any hostname.
//
// It calls the App Platform origin directly, which is what lets it reach
// /api/v1/internal/* despite the WAF rule blocking that path on the public
// hostname (spec §12.3).
//
// Scheduled tasks are never authoritative (spec §12.1). If this Worker stops
// running entirely, expired Wars still reject votes — the API evaluates
// ends_at lazily on every read and write. Only the stored status column falls
// behind, so a failure here is a housekeeping incident, not an outage.

const TASKS = [
  { name: 'close-expired-wars', path: '/api/v1/internal/close-expired-wars' },
]

export default {
  async scheduled(event, env, ctx) {
    const failures = []

    for (const task of TASKS) {
      try {
        const result = await run(task, env)
        console.log(`[${task.name}] ok`, JSON.stringify(result))
      } catch (error) {
        console.error(`[${task.name}] failed:`, error.message)
        failures.push(`${task.name}: ${error.message}`)
      }
    }

    // Throwing marks the invocation failed, which is what surfaces in edge
    // analytics and drives the "2 consecutive failed runs" alert (spec §12.4).
    if (failures.length > 0) {
      throw new Error(failures.join('; '))
    }
  },
}

async function run(task, env) {
  const response = await fetch(`${env.API_BASE_URL}${task.path}`, {
    method: 'POST',
    headers: {
      'X-Internal-Token': env.INTERNAL_TASK_TOKEN,
      'content-type': 'application/json',
    },
  })

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`)
  }

  // Every task is idempotent (spec §12.2), so a retry after a partial failure
  // is safe and needs no coordination here.
  return response.json()
}
