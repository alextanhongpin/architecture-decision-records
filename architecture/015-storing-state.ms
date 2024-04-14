# Storing state

Instead of tracking state individually for a sequence of actions,e.g. saga, we can represent it using int.

E.g. we have 3 sequential actions, book hotel, book flight and make payment.

We start with `0`. Once it is pending, we make it `100,110,111`.

The advantage is we can check if the count is higher (next state).
