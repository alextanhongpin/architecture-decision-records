## How to validate string unions

```ts
const CHAT_TYPES = ['private', 'group'] as const 

type ChatType = typeof CHAT_TYPES[number]

function isChatType(t: string): t is ChatType {
    return CHAT_TYPES.includes(t as ChatType)
}

function assertIsChatType(t: string): asserts t is ChatType {
    if (!isChatType(t)) {
        throw new TypeError(`ChatType: invalid value "${t}"`)    
    }
}

function print(t: ChatType) {
    console.log(t)
}

const data = {
    type: 'private'
}

assertIsChatType(data.type)
print(data.type)
```
