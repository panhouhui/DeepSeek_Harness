import assert from 'node:assert/strict'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import Include from '@deepseek-ai/cordis-plugin-include'
import Extensions from '@deepseek-ai/dsh-deepseek-llm-api-extensions'
import * as Kanai from './request-fields.mjs'

const config = {
  model: 'gateway-model', webSearch: 'auto', priority: 0, normalEffort: 20, maxEffort: 100,
}

async function composition(t, values = config) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-kanai-'))
  const ctx = new Context()
  t.after(async () => {
    try { await ctx.fiber.dispose() } finally { await rm(root, { recursive: true, force: true }) }
  })
  await ctx.plugin(Loader)
  ctx.loader.builtins.include = Include
  ctx.loader.builtins.extensions = Extensions
  ctx.loader.builtins.kanai = Kanai
  const file = join(root, 'cordis.yml')
  await writeFile(file, JSON.stringify([
    { id: 'extensions', name: 'cordis:extensions' },
    { id: 'kanai', name: 'cordis:kanai', config: values },
  ]))
  await ctx.loader.create({ name: 'cordis:include', config: { path: pathToFileURL(file).href } })
  await ctx.loader.await()
  return ctx
}

async function fields(ctx, body, purpose) {
  const prepared = await ctx.deepseekLlmApiExtensions.prepare({
    body: { model: config.model, ...body },
    signal: new AbortController().signal,
    ...(purpose === undefined ? {} : { purpose }),
  })
  await prepared.accept()
  return { ...prepared.fields }
}

test('Loader composition maps fast, normal, and max requests', async (t) => {
  const ctx = await composition(t)
  assert.deepEqual(await fields(ctx, { thinking: { type: 'disabled' } }), {
    chat_template_kwargs: { enable_thinking: false }, enable_web_search: 'auto', priority: 0,
  })
  for (const effort of ['low', 'high', 'max']) {
    assert.deepEqual(await fields(ctx, { thinking: { type: 'enabled' }, reasoning_effort: effort }), {
      chat_template_kwargs: { enable_thinking: true, reasoning_effort: effort === 'max' ? 100 : 20 },
      enable_web_search: 'auto', priority: 0,
    })
  }
  assert.equal('default' in Kanai, false)
})

test('title and compaction requests never trigger gateway web search', async (t) => {
  const ctx = await composition(t)
  for (const purpose of ['session-title', 'compaction']) {
    const result = await fields(ctx, { thinking: { type: 'disabled' } }, purpose)
    assert.equal(result.enable_web_search, 'off')
    assert.equal(result.chat_template_kwargs.enable_thinking, false)
  }
})

test('unrelated models receive no gateway fields', async (t) => {
  const ctx = await composition(t)
  assert.deepEqual(await fields(ctx, { model: 'another-model' }), {})
})

test('deployment values reach the request', async (t) => {
  const ctx = await composition(t, { ...config, webSearch: 'force', priority: 10, normalEffort: 35 })
  assert.deepEqual(await fields(ctx, { thinking: { type: 'enabled' } }), {
    chat_template_kwargs: { enable_thinking: true, reasoning_effort: 35 },
    enable_web_search: 'force', priority: 10,
  })
})

test('disposing the plugin releases every registered request field', async (t) => {
  const ctx = new Context()
  t.after(() => ctx.fiber.dispose())
  await ctx.plugin(Extensions)
  const fiber = ctx.plugin(Kanai, config)
  await fiber
  assert.equal(Object.keys(await fields(ctx, {})).length, 3)
  await fiber.dispose()
  assert.deepEqual(await fields(ctx, {}), {})
})

test('invalid deployment config fails before registration', () => {
  for (const invalid of [
    { model: '' }, { webSearch: 'yes' }, { priority: 0.5 },
    { normalEffort: 0 }, { normalEffort: 101 }, { maxEffort: 2.5 },
  ]) {
    assert.throws(() => Kanai.apply({}, { ...config, ...invalid }), /kanai-request-fields:/)
  }
})
