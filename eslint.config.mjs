import af from '@alienfast/eslint-config'
import { defineConfig } from 'eslint/config'

/**
 * Project eslint configuration.
 *
 * View config with `npx @eslint/config-inspector`
 */
export default defineConfig([
  af.configs.recommended,
  {
    name: 'project',
    rules: {
      'markdown/no-missing-label-refs': 'off', // too many false positives on .claude files, move up to preset.
    },
  },
  { ignores: ['ide', 'pics', 'projects', 'shell-snapshots', 'statsig', 'todos', 'tmp'] },
])
