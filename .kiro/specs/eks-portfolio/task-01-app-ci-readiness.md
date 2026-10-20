# Task 1 - Make the app CI-ready

## Status
- [ ] Not started / - [x] Done

## Objective
Tests and lint pass non-interactively, so the Jenkins "Lint & Test" stage is a real quality gate.

## Dependencies
None.

## Files to create/modify
- `src/App.test.tsx` (rewrite)
- `src/setupTests.ts` (jsdom mocks)
- `package.json` (`lint`, `test:ci` scripts)

## Implementation guidance
- Replace the default CRA "learn react" test with tests that:
  - render the app without crashing
  - check key sections (name heading, Expertise, Contact Me)
  - check that the mode toggle switches the `dark-mode`/`light-mode` class
- Mock `window.scrollTo` and `IntersectionObserver` in `setupTests.ts`.
- Add `"lint": "eslint --max-warnings=0 src"` and `"test:ci": "react-scripts test --watchAll=false --coverage"`.
- Fix any lint warnings that come up.

## Test requirements
- `$env:CI='true'; npm run test:ci` exits 0.
- `npm run lint` exits 0.

## Demo / acceptance criteria
Both commands exit 0 locally, with green test output.

## Interview talking points
- `CI=true` turns off CRA's watch mode and makes warnings fail the build, so the pipeline can't hang.
- The default CRA test would have either failed every build or, if deleted, left no gate at all. A test that checks real behaviour (the theme toggle) is a meaningful gate.
- `--max-warnings=0` keeps lint debt from growing quietly.
