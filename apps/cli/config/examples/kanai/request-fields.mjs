/** Add the Kanai gateway's template, search, and scheduler fields to DeepSeek requests. */
export const name = 'kanai-request-fields'
export const inject = ['deepseekLlmApiExtensions']

/** Register request fields only for the configured gateway model; disposal releases all fields. */
export function apply(ctx, config) {
  if (typeof config.model !== 'string' || config.model.trim().length === 0) {
    throw new Error('kanai-request-fields: model must be a non-empty string')
  }
  if (!['off', 'auto', 'force'].includes(config.webSearch)) {
    throw new Error('kanai-request-fields: webSearch must be off, auto, or force')
  }
  if (!Number.isSafeInteger(config.priority)) {
    throw new Error('kanai-request-fields: priority must be an integer')
  }
  for (const field of ['normalEffort', 'maxEffort']) {
    if (!Number.isInteger(config[field]) || config[field] < 1 || config[field] > 100) {
      throw new Error(`kanai-request-fields: ${field} must be an integer from 1 to 100`)
    }
  }
  const register = (field, value) => ctx.deepseekLlmApiExtensions.register(field, {
    prepare(request) {
      if (request.body.model !== config.model) return undefined
      return { value: value(request) }
    },
  })
  register('chat_template_kwargs', ({ body }) => {
    if (body.thinking?.type === 'disabled') return { enable_thinking: false }
    return {
      enable_thinking: true,
      reasoning_effort: body.reasoning_effort === 'max' ? config.maxEffort : config.normalEffort,
    }
  })
  register('enable_web_search', ({ purpose }) => (
    purpose === 'session-title' || purpose === 'compaction' ? 'off' : config.webSearch
  ))
  register('priority', () => config.priority)
}
