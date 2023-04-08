## Setting absolute import with NODE_PATH

Say we have the following folder structure:
```
src
  - infra
    - db.ts
  - index.ts
```

And we want to import the db as follow:
```ts
import { connect } from 'infra/db'
```

It is not possible, since this will be treated as a package. However, we can set `NODE_PATH=src` to allow the package to search for our own modules before resolving to external packages.

Modify `package.json` as follow:

```json5
  "main": "src/index.ts",
  "scripts": {
    "dev": "NODE_PATH=./src nodemon", // This will ensure we can resolve any absolute imports from src/ folder
    "build": "tsc",
    "start": "NODE_PATH=./dist node dist/index.js", // NOTE: When running the compiled scripts, we need to do the same for dist/ folder
    "lint": "eslint --fix . --ext .ts"
  },
```

Reference here [^1].


[^1]: https://github.com/Microsoft/TypeScript/issues/29272
