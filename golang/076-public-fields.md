# Public Fields

For golang structs, we should use public fields as much as possible.

Structs with a lot of options especially should have public fields, so that we don't end up with large constructors, especially since the order of arguments matters.

Instead, assign the default values directly in the constructor.

We don't have to worry about modifying the values, because when working with the struct, we can always define interface on what methods are accessible.

We can assume no other calls will modify the options.
