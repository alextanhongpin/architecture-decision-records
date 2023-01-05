## How to validate string unions

```ts
const CHAT_TYPES = ['private', 'group'] as const 

type ChatType = typeof CHAT_TYPES[number]

function isChatType(t: string): t is ChatType {
    return CHAT_TYPES.includes(t as ChatType)
}

function parseChatType(t: string): ChatType {
    if (isChatType(t)) {
        return t as ChatType
    }
    throw new TypeError(`ChatType: invalid value "${t}"`)
}

function print(t: ChatType) {
    console.log(t)
}

const data = {
    type: 'test'
}

print(parseChatType(data.type))
```
