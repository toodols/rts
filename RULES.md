1. Modules may only depend on siblings, children, or modules at the top level (client, server, shared)
2. Modules must always return an immutable dictionary
3. For all implementation files, code must be organized into
	1. Service imports
	2. Dependencies from shared
	3. Dependencies from server
	4. Dependencies from client
	5. Dependencies from siblings
	6. Dependencies from children
	7. Module item aliases
	8. Type dependencies
		1. Shared types
		2. Server types
		3. Client types
	9. Constant/immutable declarations
	10. Functions
	11. Export
4. `local method = require(...).method` may only be used if the module has exactly one export.
All other requires must follow the format `local module = require(...)`
5. All functions must have type annotations in the parameters and the return type, unless it returns nil.
6. Any time `func(...)` can be rewritten as `func ...`, it must.
7. A check against a nil must always use == or ~=.

	Example: let `foo: T?`
	- Do: `if foo == nil then ... end`
	- Do not: `if not foo then ... end`
8. Ternaries of the form `a and b or c` are illegal in favor of `if a then b else c`
9. Variable Cases
	- All user variables use snake_case
		- Unless it is a react component, then it will use PascalCase
	- All user types use PascalCase
	- All user table keys use snake_case
	- Unless they correspond directly to an api/library item, then it will copy that item's name.
		- Ex: Players, React, LayoutOrder
10. No OOP allowed. No metatables and objects. These objects are hard to serialize.
