# Maps naming convention

Most of the time, we need to keep mapping of one variable to another. It can be multiple nested layers.


E.g.
```
users_by_id = {
	1: 'alice',
	2: 'bob'
}

users_by_id_by_room = {
	room1: {
		1: 'alice',
		2: 'bob'
	},
	room2: {
		3: 'charles'
	}
}

users_by_id = users_by_id[room1]
```

Above we are using the convention `valueByKey`, because I read somewhere that it sounds more natural than `keyToValue`.

However, `keyToValue` actually sounds easier to comprehend:

```
room_to_id_to_user = {
	room1: {
		1: 'alice',
		2: 'bob'
	},
	room2: {
		3: 'charles'
	}
}

id_to_user = room_to_id_to_user[room1]
```
