# Framework-Specific Migration Guides

Quick reference for finding official migration guides and handling framework-specific deprecations.

## React

### Official Resources

- **React 18 Upgrade Guide**: <https://react.dev/blog/2022/03/08/react-18-upgrade-guide>
- **Legacy API Reference**: <https://react.dev/reference/react/legacy>
- **Migration from Classes to Hooks**: <https://react.dev/learn/migrating-a-component-to-typescript>

### Common React Deprecations

| Deprecated | Replacement | Guide |
|------------|-------------|-------|
| `React.createClass` | Function components or `class extends React.Component` | [Link](https://react.dev/reference/react/Component) |
| `componentWillMount` | `useEffect` with empty deps or constructor | [Link](https://react.dev/reference/react/Component#componentwillmount) |
| `componentWillReceiveProps` | `useEffect` with dependencies | [Link](https://react.dev/reference/react/Component#componentwillreceiveprops) |
| `componentWillUpdate` | `useEffect` | [Link](https://react.dev/reference/react/Component#componentwillupdate) |
| `UNSAFE_*` lifecycle methods | Modern alternatives | [Link](https://react.dev/blog/2018/03/27/update-on-async-rendering) |
| `findDOMNode` | Refs | [Link](https://react.dev/reference/react-dom/findDOMNode) |
| `ReactDOM.render` | `ReactDOM.createRoot` (React 18+) | [Link](https://react.dev/blog/2022/03/08/react-18-upgrade-guide#updates-to-client-rendering-apis) |

### React Router Migrations

- **v5 → v6**: <https://reactrouter.com/en/main/upgrading/v5>

Key changes:

```typescript
// v5 (deprecated)
<Switch>
  <Route path="/about" component={About} />
</Switch>

// v6 (modern)
<Routes>
  <Route path="/about" element={<About />} />
</Routes>
```

## Vue

### Official Resources

- **Vue 3 Migration Guide**: <https://v3-migration.vuejs.org/>
- **Breaking Changes**: <https://v3-migration.vuejs.org/breaking-changes/>

### Vue 2 → Vue 3 Key Changes

| Deprecated | Replacement | Notes |
|------------|-------------|-------|
| Global Vue API | `createApp()` | No more `new Vue()` |
| `$on`, `$off`, `$once` | External event bus or provide/inject | Event bus pattern removed |
| Filters | Methods or computed properties | Pipe syntax removed |
| `v-model` default prop | Can be customized | Default changed from `value` |
| `$listeners` | Merged into `$attrs` | Simplified props/attrs handling |

## Angular

### Official Resources

- **Update Guide**: <https://update.angular.io/>
- **Deprecation Guide**: <https://angular.dev/reference/migrations>

### Angular Version Deprecations

Use Angular Update Guide for version-specific migrations:

```bash
# Interactive update tool
npx @angular/cli@latest update
```

Common patterns:

- `ngModel` with reactive forms → Use `formControl` only
- `ModuleWithProviders` without generic → Add type parameter
- `ViewEncapsulation.Native` → `ViewEncapsulation.ShadowDom`

## Next.js

### Official Resources

- **Upgrade Guide**: <https://nextjs.org/docs/upgrading>
- **Codemods**: <https://nextjs.org/docs/app/building-your-application/upgrading/codemods>

### Next.js 13+ App Router Migration

```bash
# Automated migration
npx @next/codemod@latest app-router-migration
```

Key changes:

- Pages Router → App Router (`pages/` → `app/`)
- `getServerSideProps` → Server Components
- `getStaticProps` → `generateStaticParams`

## TypeScript

### Official Resources

- **Breaking Changes**: <https://github.com/microsoft/TypeScript/wiki/Breaking-Changes>
- **Release Notes**: <https://www.typescriptlang.org/docs/handbook/release-notes/>

### Version-Specific Guides

Check specific version upgrade guides:

- TypeScript 5.0: <https://devblogs.microsoft.com/typescript/announcing-typescript-5-0/>
- TypeScript 4.0: <https://devblogs.microsoft.com/typescript/announcing-typescript-4-0/>

## Node.js

### Official Resources

- **API Deprecations**: <https://nodejs.org/api/deprecations.html>
- **Version Guide**: <https://github.com/nodejs/node/blob/main/doc/changelogs/>

### Tracking Deprecations

```bash
# Run with deprecation warnings
node --trace-deprecation app.js

# Throw on deprecations (testing)
node --throw-deprecation app.js
```

Common deprecated APIs:

- `Buffer()` constructor → `Buffer.from()`, `Buffer.alloc()`
- `url.parse()` → `new URL()`
- `require.extensions` → Use proper loaders

## Testing Libraries

### React Testing Library

- **Migration from Enzyme**: <https://testing-library.com/docs/react-testing-library/migrate-from-enzyme>

### Jest

- **Breaking Changes**: <https://jestjs.io/docs/upgrading-to-jest29>

## Package Ecosystem

### Deprecated Package Alternatives

| Deprecated Package | Reason | Modern Alternative |
|-------------------|--------|-------------------|
| `request` | Unmaintained | `axios`, `node-fetch`, `got` |
| `moment` | Large bundle size | `date-fns`, `dayjs`, `luxon` |
| `tslint` | Deprecated | `eslint` with `@typescript-eslint` |
| `node-sass` | Slow, deprecated | `sass` (Dart Sass) |
| `babel-eslint` | Deprecated | `@babel/eslint-parser` |

### Finding Alternatives

```bash
# Check package deprecation status
npm view <package-name>

# Alternative lookup
npx npm-check-updates
```

## UI Frameworks

### Material-UI (MUI)

- **v4 → v5 Migration**: <https://mui.com/material-ui/migration/migration-v4/>
- **Codemods**: <https://github.com/mui/material-ui/tree/master/packages/mui-codemod>

```bash
npx @mui/codemod v5.0.0/preset-safe <path>
```

### Ant Design

- **v4 → v5**: <https://ant.design/docs/react/migration-v5>

### Chakra UI

- **v1 → v2**: <https://chakra-ui.com/getting-started/migration>

## CSS-in-JS

### styled-components

- **v5 → v6**: <https://styled-components.com/docs/faqs#what-do-i-need-to-do-to-migrate-to-v6>

### Emotion

- **v10 → v11**: <https://emotion.sh/docs/emotion-11>

## Build Tools

### Webpack

- **v4 → v5**: <https://webpack.js.org/migrate/5/>

### Vite

- **Migration from Webpack**: <https://vitejs.dev/guide/migration.html>

## State Management

### Redux

- **Redux Toolkit Migration**: <https://redux-toolkit.js.org/usage/migrating-to-modern-redux>

```typescript
// Old: createStore (deprecated)
const store = createStore(rootReducer);

// New: configureStore (Redux Toolkit)
const store = configureStore({
  reducer: rootReducer
});
```

### MobX

- **v5 → v6**: <https://mobx.js.org/migrating-from-4-or-5.html>

## General Migration Strategy

### Using Codemods

Many frameworks provide automated migration tools:

```bash
# React
npx react-codemod <transform> <path>

# Next.js
npx @next/codemod <transform> <path>

# Material-UI
npx @mui/codemod <transform> <path>
```

### Version-by-Version Strategy

For major version upgrades:

1. Review official migration guide
2. Run codemods if available
3. Update dependencies incrementally
4. Fix TypeScript/linting errors
5. Run full test suite
6. Manual testing
7. Deploy to staging environment

### Documentation Pattern

When migration is blocked:

```typescript
/**
 * DEPRECATION: Using legacy API from framework-v2
 *
 * Status: Blocked by dependency on auth-library@1.x
 * auth-library requires framework-v2 API until v2 release
 *
 * Migration Guide: https://framework.com/docs/v2-to-v3
 * Tracking Issue: https://github.com/auth-library/issues/456
 * Target: Q3 2025 (when auth-library@2.0 releases)
 *
 * TODO: Migrate to framework-v3 when auth-library supports it
 */
framework.deprecatedApi();
```
