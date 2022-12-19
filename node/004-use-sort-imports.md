# use-sort-imports


## Installation

```bash
$ npm install --save-dev eslint-plugin-simple-import-sort
```


## Configuration

Add the following rules to `.eslintrc`:

```json
{
  "plugins": ["simple-import-sort"],
  "rules": {
    "simple-import-sort/exports": "error",
    "simple-import-sort/imports": "error"
  }
}
```


Update `package.json` to enable auto-fix:

```json
  "scripts": {
    "lint": "eslint --fix . --ext .ts"
  },
```
