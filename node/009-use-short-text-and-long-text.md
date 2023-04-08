# Use Short Text and Long Text

Restricting text length and types is a good practice in your application, to prevent users from sending extremely long text. When using database such as MySQL too which has varchar limitation, it is preferable to warn users that their text exceeds certain length instead of just truncating them when storing in the database. Some database like Postgres does not have limitation in text length, however, it is still advisable to limit the text length based on business requirements.

```ts
type Brand<T, U> = T & {__type: U}

type ShortText = Brand<string, 'SHORT_TEXT'>
type LongText = Brand<string, 'LONG_TEXT'>

function assertIsShortText(text: string): asserts text is ShortText {
    if (text.length > 255) throw new Error('too long')
}

function assertIsLongText(text: string): asserts text is LongText {
    if (text.length > 1000) throw new Error('too long')
}

function printShortText(text: ShortText) {
    console.log(text)
}

const text = 'short text'.repeat(1000)
assertIsShortText(text)
printShortText(text)
```
