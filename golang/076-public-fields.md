# Public Fields

For golang structs, we should use public fields as much as possible.

Structs with a lot of options especially should have public fields, so that we don't end up with large constructors, especially since the order of arguments matters.

Instead, assign the default values directly in the constructor.

We don't have to worry about modifying the values, because when working with the struct, we can always define interface on what methods are accessible.

We can assume no other calls will modify the options.

## Constructor 

Since fields are public, do we still need constructor?

The answer is yes. For example, we may want to make certain fields mandatory, so passing them through constructor is a good way.

We may also want to initialize some sane defaults, like an empty map.

If the constructor args may impact several fields, consider a setter method that will ensure the changes are atomic.
